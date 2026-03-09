// shell/handler.zig
// Shell imperativo: executa Acao prescrita pelo core puro.
//
// Fluxo por mensagem:
//   1. handleMensagem → carrega config do DB (se disponível)
//   2. processar(msg, config) → Acao
//   3. executarAcao → efeito (DB + enviarFn)
//
// Memória:
//   cfg_arena  — arena para strings de config vindas do DB (system_prompt,
//                prompt_ativo). Resetado a cada handleMensagem.
//   allocator  — alocações temporárias de request (histórico, formatação).
//                Liberadas antes de executarAcao retornar.

const std       = @import("std");
const proc      = @import("../core/processador.zig");
const acao_m    = @import("../dominio/acao.zig");
const msg_m     = @import("../dominio/mensagem.zig");
const cfg_m     = @import("../dominio/config.zig");
const sqlite    = @import("../infra/sqlite.zig");
const fila      = @import("fila_midia.zig");
const scraper   = @import("../infra/scraper.zig");
const cache_ia_m = @import("../infra/cache_ia.zig");

pub const Mensagem = msg_m.Mensagem;
pub const Acao     = acao_m.Acao;
pub const Config   = cfg_m.Config;
pub const Db       = sqlite.Db;

// ---------------------------------------------------------------------------
// Contexto(IA) — shell completo para um chat
// ---------------------------------------------------------------------------
//
// IA: duck-typed — qualquer struct com gerarTexto + processarMidia.
// Na produção: Resiliente(GeminiAdapter).
// Nos testes:  MockIA.
//
// enviarFn: injetado para desacoplar do transporte (WhatsApp, testes, etc.).

pub fn Contexto(comptime IA: type) type {
    return struct {
        ia:        *IA,
        config:    Config,
        chat_id:   []const u8,
        allocator: std.mem.Allocator,
        cfg_arena: std.heap.ArenaAllocator,
        enviarFn:  *const fn ([]const u8, []const u8) void,
        reagirFn:  *const fn ([]const u8, []const u8, []const u8) void,
        db:        ?*Db = null,
        fila_midia: ?*fila.FilaMidia(IA) = null,
        cache_ia:  ?*cache_ia_m.CacheIA = null,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.cfg_arena.deinit();
        }

        fn cfgAlloc(self: *Self) std.mem.Allocator {
            return self.cfg_arena.allocator();
        }

        // -----------------------------------------------------------------------
        // handleMensagem — entry point por request
        // -----------------------------------------------------------------------

        pub fn handleMensagem(self: *Self, msg: Mensagem) !void {
            // Carrega config fresca do DB a cada mensagem.
            // cfg_arena é resetada aqui — invalida strings da rodada anterior.
            if (self.db) |db| {
                _ = self.cfg_arena.reset(.retain_capacity);
                self.config = if (try db.carregarConfig(self.chat_id, self.cfgAlloc())) |cfg|
                    cfg
                else
                    Config{ .chat_id = self.chat_id };

                // Registra/atualiza usuário com pushName (nome de exibição do Baileys)
                if (msg.push_name) |nome| {
                    db.registrarUsuario(msg.remetente, nome, msg.eh_admin) catch |err| {
                        std.log.warn("Falha ao registrar usuário {s}: {}", .{ msg.remetente, err });
                    };
                }
            }

            const ac = proc.processar(msg, self.config);
            try self.executarAcao(ac, msg.id);
        }

        // -----------------------------------------------------------------------
        // executarAcao — efeitos colaterais
        // -----------------------------------------------------------------------

        pub fn executarAcao(self: *Self, ac: Acao, msg_id: []const u8) !void {
            switch (ac) {
                .ignorar => {},

                .responder => |texto| {
                    self.enviarFn(self.chat_id, texto);
                },

                .invocar_ia => |inv| try self.executarInvocarIA(inv, msg_id),

                .enfileirar_midia => |midia| {
                    if (self.fila_midia) |fm| {
                        const sp = if (self.config.system_prompt.len > 0) self.config.system_prompt else null;
                        fm.enfileirar(self.chat_id, msg_id, midia, sp) catch |err| {
                            std.log.err("Erro ao enfileirar mídia: {}", .{err});
                            self.enviarFn(self.chat_id, "❌ Erro interno ao enfileirar mídia.");
                        };
                    } else {
                        self.enviarFn(self.chat_id, "⚠️ Fila de mídia não configurada.");
                    }
                },

                .reagir => |r| {
                    self.reagirFn(self.chat_id, r.msg_id, r.emoji);
                },

                .alterar_config => |alt| {
                    cfg_m.aplicarAlteracao(&self.config, .{ .campo = alt.campo, .valor = alt.valor });
                    try self.salvarConfigAtual();
                    const ok = try std.fmt.allocPrint(
                        self.allocator, "✅ {s} = {s}", .{ alt.campo, alt.valor },
                    );
                    defer self.allocator.free(ok);
                    self.enviarFn(self.chat_id, ok);
                },

                .resetar_config => {
                    if (self.db) |db| try db.deletarConfig(self.chat_id);
                    _ = self.cfg_arena.reset(.retain_capacity);
                    self.config = Config{ .chat_id = self.chat_id };
                    self.enviarFn(self.chat_id, "✅ Configuração resetada.");
                },

                .ativar_modo_cego => {
                    self.config.modo_descricao = .cego;
                    try self.salvarConfigAtual();
                    self.enviarFn(self.chat_id, "✅ Modo descrição para cego ativado.");
                },

                .salvar_prompt => |sp| {
                    if (self.db) |db| {
                        try db.salvarPrompt(self.chat_id, sp.nome, sp.conteudo);
                        const ok = try std.fmt.allocPrint(
                            self.allocator, "✅ Prompt '{s}' salvo.", .{sp.nome},
                        );
                        defer self.allocator.free(ok);
                        self.enviarFn(self.chat_id, ok);
                    } else {
                        self.enviarFn(self.chat_id, "✅ Prompt salvo.");
                    }
                },

                .ativar_prompt => |nome| {
                    if (self.db) |db| {
                        if (try db.obterPrompt(self.chat_id, nome, self.cfgAlloc())) |conteudo| {
                            self.config.system_prompt = conteudo;
                            self.config.prompt_ativo  = try self.cfgAlloc().dupe(u8, nome);
                            try self.salvarConfigAtual();
                            const ok = try std.fmt.allocPrint(
                                self.allocator, "✅ Prompt '{s}' ativado.", .{nome},
                            );
                            defer self.allocator.free(ok);
                            self.enviarFn(self.chat_id, ok);
                        } else {
                            const err = try std.fmt.allocPrint(
                                self.allocator, "❌ Prompt '{s}' não encontrado.", .{nome},
                            );
                            defer self.allocator.free(err);
                            self.enviarFn(self.chat_id, err);
                        }
                    } else {
                        self.enviarFn(self.chat_id, "✅ Prompt ativado.");
                    }
                },

                .deletar_prompt => |nome| {
                    if (self.db) |db| {
                        try db.deletarPrompt(self.chat_id, nome);
                        const ok = try std.fmt.allocPrint(
                            self.allocator, "✅ Prompt '{s}' deletado.", .{nome},
                        );
                        defer self.allocator.free(ok);
                        self.enviarFn(self.chat_id, ok);
                    } else {
                        self.enviarFn(self.chat_id, "✅ Prompt deletado.");
                    }
                },

                .limpar_prompt_ativo => {
                    self.config.system_prompt = "";
                    self.config.prompt_ativo  = null;
                    try self.salvarConfigAtual();
                    self.enviarFn(self.chat_id, "✅ Prompt ativo removido.");
                },

                .listar_prompts => {
                    if (self.db) |db| {
                        const lista = try db.listarPrompts(self.chat_id, self.allocator);
                        defer {
                            for (lista) |s| self.allocator.free(s);
                            self.allocator.free(lista);
                        }
                        if (lista.len == 0) {
                            self.enviarFn(self.chat_id, "(nenhum prompt salvo)");
                        } else {
                            var buf = std.ArrayListUnmanaged(u8){};
                            defer buf.deinit(self.allocator);
                            try buf.writer(self.allocator).writeAll("Prompts:\n");
                            for (lista) |nome| {
                                try buf.writer(self.allocator).print("• {s}\n", .{nome});
                            }
                            self.enviarFn(self.chat_id, buf.items);
                        }
                    } else {
                        self.enviarFn(self.chat_id, "(nenhum prompt salvo)");
                    }
                },

                .listar_usuarios => {
                    if (self.db) |db| {
                        const lista = try db.listarUsuarios(self.allocator);
                        defer {
                            for (lista) |u| {
                                self.allocator.free(u.jid);
                                self.allocator.free(u.nome);
                            }
                            self.allocator.free(lista);
                        }
                        if (lista.len == 0) {
                            self.enviarFn(self.chat_id, "👥 Nenhum usuário registrado.");
                        } else {
                            var buf = std.ArrayListUnmanaged(u8){};
                            defer buf.deinit(self.allocator);
                            try buf.writer(self.allocator).print(
                                "👥 Usuários ({d}):\n", .{lista.len},
                            );
                            for (lista) |u| {
                                const tag = if (u.eh_admin) " (admin)" else "";
                                try buf.writer(self.allocator).print(
                                    "• {s}{s}\n", .{ u.nome, tag },
                                );
                            }
                            self.enviarFn(self.chat_id, buf.items);
                        }
                    } else {
                        self.enviarFn(self.chat_id, "👥 Nenhum usuário registrado.");
                    }
                },

                .obter_status => {
                    const status = try self.montarStatus();
                    defer self.allocator.free(status);
                    self.enviarFn(self.chat_id, status);
                },

                .limpar_filas => {
                    if (self.fila_midia) |fm| {
                        fm.limparFilas(self.chat_id);
                        self.enviarFn(self.chat_id, "✅ Filas limpas.");
                    } else {
                        self.enviarFn(self.chat_id, "✅ Filas limpas.");
                    }
                },
            }
        }

        // -----------------------------------------------------------------------
        // Helpers privados
        // -----------------------------------------------------------------------

        fn executarInvocarIA(self: *Self, inv: Acao.InvocarIA, msg_id: []const u8) !void {
            self.reagirFn(self.chat_id, msg_id, "⏳");

            // System prompt: override do Acao > config do chat > null
            const sp: ?[]const u8 = inv.system_prompt orelse
                if (self.config.system_prompt.len > 0) self.config.system_prompt
                else null;

            // Enriquecer o prompt se houver URL
            const prompt_enriquecido = try self.extrairEAnexarUrls(inv.prompt);
            defer self.allocator.free(prompt_enriquecido);

            // Verifica cache de IA antes de chamar a API (apenas para prompts simples sem histórico)
            if (self.cache_ia) |cache| {
                if (!inv.incluir_historico) {
                    if (cache.obter(prompt_enriquecido, sp, self.allocator)) |cached| {
                        defer self.allocator.free(cached);
                        self.reagirFn(self.chat_id, msg_id, "🆗");
                        self.enviarFn(self.chat_id, cached);
                        return;
                    }
                }
            }

            // Prompt: enriquece com histórico se disponível e solicitado
            const prompt_final = if (inv.incluir_historico)
                try self.montarPromptComHistorico(prompt_enriquecido)
            else
                try self.allocator.dupe(u8, prompt_enriquecido);
            defer self.allocator.free(prompt_final);

            const resp = try self.ia.gerarTexto(prompt_final, sp, self.allocator);
            defer self.allocator.free(resp);

            // Persiste turno no histórico (salva o prompt_enriquecido original sem histórico global)
            if (self.db) |db| {
                try db.adicionarHistorico(self.chat_id, "user",  prompt_enriquecido);
                try db.adicionarHistorico(self.chat_id, "model", resp);
            }

            // Insere no cache (apenas prompts simples)
            if (self.cache_ia) |cache| {
                if (!inv.incluir_historico) {
                    cache.inserir(prompt_enriquecido, sp, resp);
                }
            }

            self.reagirFn(self.chat_id, msg_id, "🆗");
            self.enviarFn(self.chat_id, resp);
        }

        fn extrairEAnexarUrls(self: *Self, prompt_original: []const u8) ![]const u8 {
            const url_start = std.mem.indexOf(u8, prompt_original, "http://") orelse
                            std.mem.indexOf(u8, prompt_original, "https://");
            if (url_start == null) return self.allocator.dupe(u8, prompt_original);

            const idx = url_start.?;
            var url_end = idx;
            while (url_end < prompt_original.len) : (url_end += 1) {
                const c = prompt_original[url_end];
                if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '\"' or c == '\'') break;
            }
            const url = prompt_original[idx..url_end];

            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(self.allocator);
            try buf.appendSlice(self.allocator, prompt_original);

            // Limitado a 10kb
            if (scraper.extrairTextoDaUrl(self.allocator, url, 10000)) |texto_raspado| {
                defer self.allocator.free(texto_raspado);
                try buf.writer(self.allocator).print("\n\n[Conteúdo textual raspado da URL {s}]:\n{s}\n", .{ url, texto_raspado });
            } else |err| {
                try buf.writer(self.allocator).print("\n\n[Erro ao tentar raspar a URL {s}: {}]\n", .{ url, err });
            }

            return self.allocator.dupe(u8, buf.items);
        }

        /// Constrói prompt com as últimas entradas do histórico como contexto.
        /// Retorna slice alocado em self.allocator — caller libera.
        fn montarPromptComHistorico(self: *Self, prompt: []const u8) ![]const u8 {
            const db = self.db orelse return self.allocator.dupe(u8, prompt);

            const hist = try db.obterHistorico(self.chat_id, 10, self.allocator);
            defer {
                for (hist) |e| {
                    self.allocator.free(e.role);
                    self.allocator.free(e.conteudo);
                }
                self.allocator.free(hist);
            }

            if (hist.len == 0) return self.allocator.dupe(u8, prompt);

            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(self.allocator);

            for (hist) |e| {
                const label = if (std.mem.eql(u8, e.role, "model")) "Amélie" else "Usuário";
                try buf.writer(self.allocator).print("{s}: {s}\n", .{ label, e.conteudo });
            }
            try buf.writer(self.allocator).print("Usuário: {s}", .{prompt});

            // Transfere para allocator permanente (buf usa allocator interno)
            return self.allocator.dupe(u8, buf.items);
        }

        /// Salva config no DB garantindo que chat_id está correto.
        fn salvarConfigAtual(self: *Self) !void {
            const db = self.db orelse return;
            self.config.chat_id = self.chat_id;
            try db.salvarConfig(self.config);
        }

        fn montarStatus(self: *Self) ![]const u8 {
            const prompt_ativo = self.config.prompt_ativo orelse "(nenhum)";
            return std.fmt.allocPrint(
                self.allocator,
                "🤖 Amélie ativa\n" ++
                "• imagem: {s}\n" ++
                "• áudio: {s}\n" ++
                "• vídeo: {s}\n" ++
                "• doc: {s}\n" ++
                "• modo: {s}\n" ++
                "• prompt: {s}",
                .{
                    if (self.config.media_imagem)    "on" else "off",
                    if (self.config.media_audio)     "on" else "off",
                    if (self.config.media_video)     "on" else "off",
                    if (self.config.media_documento) "on" else "off",
                    self.config.modo_descricao.toStr(),
                    prompt_ativo,
                },
            );
        }
    };
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

/// MockIA captura o último prompt recebido (para testes de histórico).
/// Usa buffer fixo para evitar use-after-free quando o handler libera prompt_final.
const MockIA = struct {
    resposta:     []const u8 = "resposta mock",
    chamadas:     usize      = 0,
    deve_falhar:  bool       = false,
    _pbuf:        [8192]u8   = undefined,
    ultimo_prompt: []const u8 = "",

    pub fn gerarTexto(
        self:   *MockIA,
        prompt: []const u8,
        _sp:    ?[]const u8,
        alloc:  std.mem.Allocator,
    ) ![]const u8 {
        _ = _sp;
        self.chamadas += 1;
        const l = @min(prompt.len, self._pbuf.len);
        @memcpy(self._pbuf[0..l], prompt[0..l]);
        self.ultimo_prompt = self._pbuf[0..l];
        if (self.deve_falhar) return error.ApiError;
        return alloc.dupe(u8, self.resposta);
    }

    pub fn processarMidia(
        self:   *MockIA,
        _dados: []const u8,
        _mime:  []const u8,
        _p:     ?[]const u8,
        alloc:  std.mem.Allocator,
    ) ![]const u8 {
        _ = _dados; _ = _mime; _ = _p;
        self.chamadas += 1;
        return alloc.dupe(u8, self.resposta);
    }
};

const CtxMock = Contexto(MockIA);

/// Captura mensagens enviadas em testes.
/// Copia para buffer próprio — safe mesmo após o handler liberar o slice original.
const Captura = struct {
    chat_id:  []const u8 = "",
    texto:    []const u8 = "",
    msg_id:   []const u8 = "",
    emoji:    []const u8 = "",
    chamadas: usize      = 0,
    _tbuf:    [8192]u8   = undefined,
    _cbuf:    [256]u8    = undefined,
    _mbuf:    [256]u8    = undefined,
    _ebuf:    [64]u8     = undefined,

    var instancia: Captura = .{};

    fn reset() void { instancia = .{}; }

    fn enviar(chat_id: []const u8, texto: []const u8) void {
        const tl = @min(texto.len,   instancia._tbuf.len);
        const cl = @min(chat_id.len, instancia._cbuf.len);
        @memcpy(instancia._tbuf[0..tl], texto[0..tl]);
        @memcpy(instancia._cbuf[0..cl], chat_id[0..cl]);
        instancia.texto    = instancia._tbuf[0..tl];
        instancia.chat_id  = instancia._cbuf[0..cl];
        instancia.chamadas += 1;
    }

    fn reagir(chat_id: []const u8, msg_id: []const u8, emoji: []const u8) void {
        const cl = @min(chat_id.len, instancia._cbuf.len);
        const ml = @min(msg_id.len,  instancia._mbuf.len);
        const el = @min(emoji.len,   instancia._ebuf.len);
        @memcpy(instancia._cbuf[0..cl], chat_id[0..cl]);
        @memcpy(instancia._mbuf[0..ml], msg_id[0..ml]);
        @memcpy(instancia._ebuf[0..el], emoji[0..el]);
        instancia.chat_id = instancia._cbuf[0..cl];
        instancia.msg_id  = instancia._mbuf[0..ml];
        instancia.emoji   = instancia._ebuf[0..el];
        instancia.chamadas += 1;
    }
};

fn novoCtx(ia: *MockIA, config: Config) CtxMock {
    Captura.reset();
    return .{
        .ia        = ia,
        .config    = config,
        .chat_id   = "test_chat",
        .allocator = testing.allocator,
        .cfg_arena = std.heap.ArenaAllocator.init(testing.allocator),
        .enviarFn  = Captura.enviar,
        .reagirFn  = Captura.reagir,
    };
}

// ---------------------------------------------------------------------------
// Testes sem DB
// ---------------------------------------------------------------------------

test "ignorar: sem envio" {
    var ia  = MockIA{};
    var ctx = novoCtx(&ia, .{});
    defer ctx.deinit();
    try ctx.executarAcao(.ignorar, "test_id");
    try testing.expectEqual(@as(usize, 0), Captura.instancia.chamadas);
}

test "responder: envia texto direto" {
    var ia  = MockIA{};
    var ctx = novoCtx(&ia, .{});
    defer ctx.deinit();
    try ctx.executarAcao(.{ .responder = "Olá!" }, "test_id");
    try testing.expectEqualStrings("Olá!", Captura.instancia.texto);
}

test "invocar_ia: chama IA e envia resposta" {
    var ia  = MockIA{ .resposta = "resposta da IA" };
    var ctx = novoCtx(&ia, .{});
    defer ctx.deinit();
    try ctx.executarAcao(.{ .invocar_ia = .{ .prompt = "oi" } }, "test_id");
    try testing.expectEqual(@as(usize, 1), ia.chamadas);
    try testing.expectEqualStrings("resposta da IA", Captura.instancia.texto);
}

test "invocar_ia: usa system_prompt do config" {
    var ia  = MockIA{ .resposta = "ok" };
    var ctx = novoCtx(&ia, Config{ .system_prompt = "Seja breve." });
    defer ctx.deinit();
    try ctx.executarAcao(.{ .invocar_ia = .{ .prompt = "resuma" } }, "test_id");
    try testing.expectEqual(@as(usize, 1), ia.chamadas);
}

test "invocar_ia: falha → propaga erro" {
    var ia  = MockIA{ .deve_falhar = true };
    var ctx = novoCtx(&ia, .{});
    defer ctx.deinit();
    try testing.expectError(error.ApiError,
        ctx.executarAcao(.{ .invocar_ia = .{ .prompt = "x" } }, "test_id"));
}

test "resetar_config: restaura defaults em memória" {
    var ia  = MockIA{};
    var ctx = novoCtx(&ia, Config{ .media_audio = true });
    defer ctx.deinit();
    try ctx.executarAcao(.resetar_config, "test_id");
    try testing.expectEqual(false, ctx.config.media_audio);
    try testing.expectEqualStrings("✅ Configuração resetada.", Captura.instancia.texto);
}

test "ativar_modo_cego: muda config e confirma" {
    var ia  = MockIA{};
    var ctx = novoCtx(&ia, .{});
    defer ctx.deinit();
    try ctx.executarAcao(.ativar_modo_cego, "test_id");
    try testing.expectEqual(cfg_m.ModoDescricao.cego, ctx.config.modo_descricao);
    try testing.expect(std.mem.indexOf(u8, Captura.instancia.texto, "cego") != null);
}

test "limpar_prompt_ativo: zera system_prompt" {
    var ia  = MockIA{};
    var ctx = novoCtx(&ia, Config{ .system_prompt = "Algum prompt." });
    defer ctx.deinit();
    try ctx.executarAcao(.limpar_prompt_ativo, "test_id");
    try testing.expectEqualStrings("", ctx.config.system_prompt);
    try testing.expectEqual(@as(?[]const u8, null), ctx.config.prompt_ativo);
}

test "obter_status: inclui campos de config" {
    var ia  = MockIA{};
    var ctx = novoCtx(&ia, Config{ .media_imagem = true, .media_audio = false });
    defer ctx.deinit();
    try ctx.executarAcao(.obter_status, "test_id");
    const t = Captura.instancia.texto;
    try testing.expect(std.mem.indexOf(u8, t, "Amélie") != null);
    try testing.expect(std.mem.indexOf(u8, t, "imagem") != null);
    try testing.expect(std.mem.indexOf(u8, t, "prompt") != null);
}

test "handleMensagem: texto → IA chamada" {
    var ia  = MockIA{ .resposta = "Olá!" };
    var ctx = novoCtx(&ia, .{});
    defer ctx.deinit();
    try ctx.handleMensagem(Mensagem{ .conteudo = .{ .texto = "oi" } });
    try testing.expectEqual(@as(usize, 1), ia.chamadas);
}

test "handleMensagem: status@broadcast → ignorar" {
    var ia  = MockIA{};
    var ctx = novoCtx(&ia, .{});
    defer ctx.deinit();
    try ctx.handleMensagem(Mensagem{
        .chat_id  = "status@broadcast",
        .conteudo = .{ .texto = "x" },
    });
    try testing.expectEqual(@as(usize, 0), ia.chamadas);
    try testing.expectEqual(@as(usize, 0), Captura.instancia.chamadas);
}

test "handleMensagem: grupo sem menção → ignorar" {
    var ia  = MockIA{};
    var ctx = novoCtx(&ia, .{});
    defer ctx.deinit();
    try ctx.handleMensagem(Mensagem{
        .em_grupo     = true,
        .menciona_bot = false,
        .conteudo     = .{ .texto = "oi grupo" },
    });
    try testing.expectEqual(@as(usize, 0), ia.chamadas);
}

// ---------------------------------------------------------------------------
// Testes com DB (banco em memória)
// ---------------------------------------------------------------------------

fn novoCtxComDb(ia: *MockIA, config: Config, db: *Db) CtxMock {
    Captura.reset();
    var ctx = novoCtx(ia, config);
    ctx.db = db;
    return ctx;
}

test "invocar_ia+DB: salva histórico (user + model)" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    var ia  = MockIA{ .resposta = "Olá!" };
    var ctx = novoCtxComDb(&ia, .{}, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.{ .invocar_ia = .{ .prompt = "oi" } }, "test_id");

    const hist = try db.obterHistorico("test_chat", 10, testing.allocator);
    defer {
        for (hist) |e| { testing.allocator.free(e.role); testing.allocator.free(e.conteudo); }
        testing.allocator.free(hist);
    }
    try testing.expectEqual(@as(usize, 2), hist.len);
    try testing.expectEqualStrings("user",  hist[0].role);
    try testing.expectEqualStrings("oi",    hist[0].conteudo);
    try testing.expectEqualStrings("model", hist[1].role);
    try testing.expectEqualStrings("Olá!",  hist[1].conteudo);
}

test "invocar_ia+DB: enriquece prompt com histórico" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();
    try db.adicionarHistorico("test_chat", "user",  "mensagem anterior");
    try db.adicionarHistorico("test_chat", "model", "resposta anterior");

    var ia  = MockIA{ .resposta = "ok" };
    var ctx = novoCtxComDb(&ia, .{}, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.{ .invocar_ia = .{ .prompt = "nova pergunta" } }, "test_id");

    try testing.expect(std.mem.indexOf(u8, ia.ultimo_prompt, "mensagem anterior") != null);
    try testing.expect(std.mem.indexOf(u8, ia.ultimo_prompt, "nova pergunta")     != null);
}

test "invocar_ia+DB: incluir_historico=false pula histórico" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();
    try db.adicionarHistorico("test_chat", "user", "contexto antigo");

    var ia  = MockIA{ .resposta = "ok" };
    var ctx = novoCtxComDb(&ia, .{}, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.{ .invocar_ia = .{
        .prompt            = "pergunta direta",
        .incluir_historico = false,
    }}, "test_id");

    // Prompt enviado à IA não deve conter o histórico
    try testing.expect(std.mem.indexOf(u8, ia.ultimo_prompt, "contexto antigo") == null);
    try testing.expectEqualStrings("pergunta direta", ia.ultimo_prompt);
}

test "alterar_config+DB: persiste no banco" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    var ia  = MockIA{};
    var ctx = novoCtxComDb(&ia, .{}, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.{ .alterar_config = .{
        .campo = "media_audio", .valor = "true",
    }}, "test_id");

    const cfg = (try db.carregarConfig("test_chat", testing.allocator)).?;
    defer testing.allocator.free(cfg.system_prompt);
    try testing.expectEqual(true, cfg.media_audio);
    try testing.expect(std.mem.indexOf(u8, Captura.instancia.texto, "media_audio") != null);
}

test "resetar_config+DB: apaga registro e reseta memória" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();
    try db.salvarConfig(Config{ .chat_id = "test_chat", .media_audio = true });

    var ia  = MockIA{};
    var ctx = novoCtxComDb(&ia, Config{ .media_audio = true }, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.resetar_config, "test_id");

    try testing.expectEqual(false, ctx.config.media_audio);
    const r = try db.carregarConfig("test_chat", testing.allocator);
    try testing.expectEqual(@as(?Config, null), r);
}

test "salvar_prompt+DB: persiste e confirma" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    var ia  = MockIA{};
    var ctx = novoCtxComDb(&ia, .{}, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.{ .salvar_prompt = .{
        .nome     = "resumo",
        .conteudo = "Resuma em 3 pontos.",
    }}, "test_id");

    const c = (try db.obterPrompt("test_chat", "resumo", testing.allocator)).?;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("Resuma em 3 pontos.", c);
    try testing.expect(std.mem.indexOf(u8, Captura.instancia.texto, "resumo") != null);
}

test "ativar_prompt+DB: carrega conteúdo e seta system_prompt" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();
    try db.salvarPrompt("test_chat", "educado", "Seja educado e objetivo.");

    var ia  = MockIA{};
    var ctx = novoCtxComDb(&ia, .{}, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.{ .ativar_prompt = "educado" }, "test_id");

    try testing.expectEqualStrings("Seja educado e objetivo.", ctx.config.system_prompt);
    try testing.expectEqualStrings("educado", ctx.config.prompt_ativo.?);
    try testing.expect(std.mem.indexOf(u8, Captura.instancia.texto, "educado") != null);
}

test "ativar_prompt+DB: nome inexistente → mensagem de erro" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    var ia  = MockIA{};
    var ctx = novoCtxComDb(&ia, .{}, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.{ .ativar_prompt = "nao_existe" }, "test_id");

    try testing.expect(std.mem.indexOf(u8, Captura.instancia.texto, "não encontrado") != null);
}

test "deletar_prompt+DB: remove do banco" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();
    try db.salvarPrompt("test_chat", "tmp", "conteúdo");

    var ia  = MockIA{};
    var ctx = novoCtxComDb(&ia, .{}, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.{ .deletar_prompt = "tmp" }, "test_id");

    const r = try db.obterPrompt("test_chat", "tmp", testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), r);
}

test "listar_prompts+DB: formata lista corretamente" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();
    try db.salvarPrompt("test_chat", "alpha", "...");
    try db.salvarPrompt("test_chat", "beta",  "...");

    var ia  = MockIA{};
    var ctx = novoCtxComDb(&ia, .{}, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.listar_prompts, "test_id");

    const t = Captura.instancia.texto;
    try testing.expect(std.mem.indexOf(u8, t, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, t, "beta")  != null);
}

test "listar_prompts+DB: chat sem prompts → mensagem vazia" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    var ia  = MockIA{};
    var ctx = novoCtxComDb(&ia, .{}, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.listar_prompts, "test_id");
    try testing.expect(std.mem.indexOf(u8, Captura.instancia.texto, "nenhum") != null);
}

test "listar_usuarios+DB: formata lista com admins" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();
    try db.registrarUsuario("5531@s.whatsapp.net", "João",  false);
    try db.registrarUsuario("5532@s.whatsapp.net", "Maria", true);

    var ia  = MockIA{};
    var ctx = novoCtxComDb(&ia, .{}, &db);
    defer ctx.deinit();

    try ctx.executarAcao(.listar_usuarios, "test_id");

    const t = Captura.instancia.texto;
    try testing.expect(std.mem.indexOf(u8, t, "João")   != null);
    try testing.expect(std.mem.indexOf(u8, t, "Maria")  != null);
    try testing.expect(std.mem.indexOf(u8, t, "admin")  != null);
}

test "handleMensagem+DB: carrega config do banco antes de processar" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();
    // Salva config com áudio habilitado
    try db.salvarConfig(Config{ .chat_id = "test_chat", .media_audio = true });

    var ia  = MockIA{ .resposta = "ok" };
    // Contexto inicia com config padrão (media_audio = false)
    var ctx = novoCtxComDb(&ia, Config{}, &db);
    defer ctx.deinit();

    // Após handleMensagem, config deve ser a do banco
    try ctx.handleMensagem(Mensagem{ .conteudo = .{ .texto = "oi" } });
    try testing.expectEqual(true, ctx.config.media_audio);
}
