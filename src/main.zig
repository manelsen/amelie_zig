const std = @import("std");
const config = @import("config.zig");
const sqlite = @import("infra/sqlite.zig");
const gemini = @import("infra/gemini.zig");
const openrouter = @import("infra/openrouter.zig");
const http = @import("infra/http.zig");
const msg_m = @import("dominio/mensagem.zig");
const handler = @import("shell/handler.zig");
const fila_midia = @import("shell/fila_midia.zig");
const cache_ia_m = @import("infra/cache_ia.zig");
const cache_mens_m = @import("infra/cache_mensagens.zig");
const telemetria_m = @import("infra/telemetria.zig");

const ResilienteGemini = @import("infra/resilience.zig").Resiliente(gemini.GeminiAdapter);
const ResilienteOpenRouter = @import("infra/resilience.zig").Resiliente(openrouter.OpenRouterAdapter);

var global_db: *sqlite.Db = undefined;
var global_ia_gemini: ?*ResilienteGemini = null;
var global_ia_openrouter: ?*ResilienteOpenRouter = null;
var global_fila_gemini: ?*fila_midia.FilaMidia(ResilienteGemini) = null;
var global_fila_openrouter: ?*fila_midia.FilaMidia(ResilienteOpenRouter) = null;
var global_cache_ia: ?*cache_ia_m.CacheIA = null;
var global_cache_mensagens: ?*cache_mens_m.CacheMensagens = null;
var global_url: []const u8 = undefined;
var global_allocator: std.mem.Allocator = undefined;
var global_encerrando: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn enviarWhatsApp(chat_id: []const u8, texto: []const u8) void {
    const ts = std.time.milliTimestamp();
    var msg_id_buf: [32]u8 = undefined;
    const msg_id = std.fmt.bufPrint(&msg_id_buf, "amelie-{d}", .{ts}) catch "amelie-0";

    if (global_db != undefined) {
        global_db.registrarTransacao(msg_id, chat_id, texto, "pending") catch {};
    }

    enviarWhatsAppRaw(msg_id, chat_id, texto);
}

// Low-level HTTP call (used by initial send and retries)
fn enviarWhatsAppRaw(msg_id: []const u8, chat_id: []const u8, texto: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var json_body = std.ArrayListUnmanaged(u8){};
    var w = json_body.writer(alloc);

    w.writeAll("{\"chat_id\":\"") catch return;
    w.writeAll(chat_id) catch return;
    w.writeAll("\",\"id\":\"") catch return;
    w.writeAll(msg_id) catch return;
    w.writeAll("\",\"texto\":\"") catch return;

    for (texto) |c| {
        switch (c) {
            '"' => w.writeAll("\\\"") catch return,
            '\\' => w.writeAll("\\\\") catch return,
            '\n' => w.writeAll("\\n") catch return,
            '\r' => w.writeAll("\\r") catch return,
            '\t' => w.writeAll("\\t") catch return,
            else => w.writeByte(c) catch return,
        }
    }
    w.writeAll("\"}") catch return;

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const uri = std.Uri.parse(global_url) catch return;
    var req = client.request(.POST, uri, .{ .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .{ .override = "identity" } } }) catch return;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = json_body.items.len };
    var payload_stream = req.sendBodyUnflushed(&.{}) catch return;
    payload_stream.writer.writeAll(json_body.items) catch return;
    payload_stream.end() catch return;
    req.connection.?.flush() catch return;

    var redirect_buf: [8192]u8 = undefined;
    _ = req.receiveHead(&redirect_buf) catch return;
}

fn reagirWhatsApp(chat_id: []const u8, msg_id: []const u8, emoji: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var json_body = std.ArrayListUnmanaged(u8){};
    var w = json_body.writer(alloc);

    w.writeAll("{\"chat_id\":\"") catch return;
    w.writeAll(chat_id) catch return;
    w.writeAll("\",\"reacao\":\"") catch return;
    w.writeAll(emoji) catch return;
    w.writeAll("\",\"msg_id\":\"") catch return;
    w.writeAll(msg_id) catch return;
    w.writeAll("\"}") catch return;

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const uri = std.Uri.parse(global_url) catch return;
    var req = client.request(.POST, uri, .{ .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .{ .override = "identity" } } }) catch return;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = json_body.items.len };
    var payload_stream = req.sendBodyUnflushed(&.{}) catch return;
    payload_stream.writer.writeAll(json_body.items) catch return;
    payload_stream.end() catch return;
    req.connection.?.flush() catch return;

    var redirect_buf: [8192]u8 = undefined;
    _ = req.receiveHead(&redirect_buf) catch return;
}

// ---------------------------------------------------------------------------
// Handlers HTTP
// ---------------------------------------------------------------------------

fn processarHttpMensagem(msg: http.Mensagem, alloc: std.mem.Allocator) []const u8 {
    _ = alloc;

    // Deduplica mensagens já processadas
    if (global_cache_mensagens) |cm| {
        if (!cm.eNova(msg.id)) return "{}";
    }

    // Copia profunda no GPA global para sobreviver ao fim do request HTTP
    const msg_copy = msg_m.Mensagem{
        .id        = global_allocator.dupe(u8, msg.id)        catch return "{}",
        .chat_id   = global_allocator.dupe(u8, msg.chat_id)   catch return "{}",
        .remetente = global_allocator.dupe(u8, msg.remetente) catch return "{}",
        .push_name = if (msg.push_name) |n| global_allocator.dupe(u8, n) catch return "{}" else null,
        .timestamp    = msg.timestamp,
        .em_grupo     = msg.em_grupo,
        .menciona_bot = msg.menciona_bot,
        .eh_admin     = msg.eh_admin,
        .conteudo = switch (msg.conteudo) {
            .texto   => |t| .{ .texto   = global_allocator.dupe(u8, t) catch return "{}" },
            .comando => |c| .{ .comando = c },
            .midia   => |m| .{ .midia   = .{
                .tipo     = m.tipo,
                .url      = global_allocator.dupe(u8, m.url)      catch return "{}",
                .caption  = if (m.caption)  |c| global_allocator.dupe(u8, c)  catch return "{}" else null,
                .mimetype = if (m.mimetype) |mt| global_allocator.dupe(u8, mt) catch return "{}" else null,
                .filename = if (m.filename) |f| global_allocator.dupe(u8, f)  catch return "{}" else null,
            }},
        },
    };

    const thread = std.Thread.spawn(.{}, asyncHandle, .{msg_copy}) catch |err| {
        std.log.err("Erro ao criar thread de processamento: {}", .{err});
        return "{}";
    };
    thread.detach();

    return "{}";
}

fn asyncHandle(msg: msg_m.Mensagem) void {
    var arena = std.heap.ArenaAllocator.init(global_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    defer {
        global_allocator.free(msg.id);
        global_allocator.free(msg.chat_id);
        global_allocator.free(msg.remetente);
        if (msg.push_name) |n| global_allocator.free(n);
        switch (msg.conteudo) {
            .texto => |t| global_allocator.free(t),
            .midia => |m| {
                global_allocator.free(m.url);
                if (m.caption)  |c| global_allocator.free(c);
                if (m.mimetype) |mt| global_allocator.free(mt);
                if (m.filename) |f| global_allocator.free(f);
            },
            else => {},
        }
    }

    var provider_is_openrouter = false;
    if (global_db != undefined) {
        var temp_arena = std.heap.ArenaAllocator.init(alloc);
        defer temp_arena.deinit();
        if (global_db.carregarConfig(msg.chat_id, temp_arena.allocator()) catch null) |c| {
            provider_is_openrouter = (c.provider == .openrouter);
        }
    }

    if (provider_is_openrouter and global_ia_openrouter != null) {
        despacharMensagem(ResilienteOpenRouter, global_ia_openrouter.?, global_fila_openrouter, msg, alloc);
    } else if (global_ia_gemini != null) {
        despacharMensagem(ResilienteGemini, global_ia_gemini.?, global_fila_gemini, msg, alloc);
    } else if (global_ia_openrouter != null) {
        despacharMensagem(ResilienteOpenRouter, global_ia_openrouter.?, global_fila_openrouter, msg, alloc);
    } else {
        std.log.err("Nenhum provedor de IA disponível para despachar.", .{});
    }
}

fn despacharMensagem(
    comptime IA: type,
    ia:  *IA,
    fm:  ?*fila_midia.FilaMidia(IA),
    msg: msg_m.Mensagem,
    alloc: std.mem.Allocator,
) void {
    var ctx = handler.Contexto(IA){
        .ia         = ia,
        .config     = handler.Config{ .chat_id = msg.chat_id },
        .chat_id    = msg.chat_id,
        .allocator  = alloc,
        .cfg_arena  = std.heap.ArenaAllocator.init(alloc),
        .enviarFn   = enviarWhatsApp,
        .reagirFn   = reagirWhatsApp,
        .db         = global_db,
        .fila_midia = fm,
        .cache_ia   = global_cache_ia,
    };
    defer ctx.deinit();

    ctx.handleMensagem(msg) catch |err| {
        std.log.err("Erro ao processar mensagem ({s}): {}", .{ msg.chat_id, err });
        reagirWhatsApp(msg.chat_id, msg.id, "❌");
    };
}

fn processarHttpAck(body_raw: []const u8, alloc: std.mem.Allocator) []const u8 {
    _ = alloc;
    if (global_db == undefined) return "{}";

    const AckPayload = struct {
        id:     ?[]const u8 = null,
        status: ?[]const u8 = null,
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_alloc = arena.allocator();

    const parsed = std.json.parseFromSlice(AckPayload, temp_alloc, body_raw, .{ .ignore_unknown_fields = true }) catch return "{}";
    defer parsed.deinit();

    const id     = parsed.value.id     orelse return "{}";
    const status = parsed.value.status orelse return "{}";

    global_db.atualizarTransacaoStatus(id, status) catch {};
    return "{\"status\":\"ok\"}";
}

/// Handler de eventos de grupo (/webhook/group).
/// Se o bot foi adicionado a um grupo não-permitido, envia saída automática.
fn processarHttpGrupo(body_raw: []const u8, alloc: std.mem.Allocator) []const u8 {
    _ = alloc;

    const GrupoPayload = struct {
        id:     ?[]const u8 = null,  // JID do grupo
        action: ?[]const u8 = null,  // "add", "remove", etc.
        bot:    ?bool       = null,  // o bot foi afetado?
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const temp_alloc = arena.allocator();

    const parsed = std.json.parseFromSlice(GrupoPayload, temp_alloc, body_raw, .{ .ignore_unknown_fields = true }) catch return "{}";
    defer parsed.deinit();

    const action = parsed.value.action orelse return "{}";
    const bot    = parsed.value.bot    orelse false;

    // Auto-leave: bot foi adicionado a um grupo
    if (std.mem.eql(u8, action, "add") and bot) {
        const grupo_id = parsed.value.id orelse return "{}";
        std.log.info("[Grupo] Bot adicionado ao grupo {s} — saindo automaticamente.", .{grupo_id});
        enviarWhatsApp(grupo_id, "Desculpe, não participo de grupos.");
    }

    return "{}";
}

fn monitorarTransacoes() void {
    std.log.info("Acks: Iniciando thread de monitoramento offline...", .{});
    while (!global_encerrando.load(.acquire)) {
        std.time.sleep(10 * std.time.ns_per_s);
        if (global_db == undefined) continue;

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        if (global_db.obterTransacoesPendentes(alloc)) |pendentes| {
            for (pendentes) |p| {
                std.log.info("Acks: Reenviando transação pendente {s} (tentativa {d})...", .{ p.id, p.tentativas + 1 });
                enviarWhatsAppRaw(p.id, p.chat_id, p.conteudo);

                const factor: i64 = @as(i64, 1) << @intCast(p.tentativas);
                const prox = std.time.timestamp() + (10 * factor);
                global_db.registrarTentativa(p.id, prox) catch {};
            }
        } else |err| {
            std.log.err("Erro ao obter transações pendentes: {}", .{err});
        }
    }
    std.log.info("Acks: Thread encerrada.", .{});
}

// ---------------------------------------------------------------------------
// Signal handler (SIGINT / SIGTERM) para encerramento gracioso
// ---------------------------------------------------------------------------

fn handleSinal(_: c_int) callconv(.C) void {
    global_encerrando.store(true, .release);
    std.log.info("Sinal recebido — encerrando Amélie...", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    global_allocator = allocator;

    var cfg = config.Config.init(allocator);
    defer cfg.deinit();

    if (std.fs.cwd().openFile(".env", .{})) |file| {
        file.close();
        try cfg.fromFile(".env");
    } else |_| {
        try cfg.fromEnv();
    }

    try cfg.validate();
    global_url = cfg.whatsapp_webhook_url;

    std.log.info("🚀 Inicializando Amélie (Zig)...", .{});

    // Instala handlers de sinal para encerramento gracioso
    const sigaction = std.posix.Sigaction{
        .handler = .{ .handler = handleSinal },
        .mask    = std.posix.empty_sigset,
        .flags   = 0,
    };
    try std.posix.sigaction(std.posix.SIG.INT,  &sigaction, null);
    try std.posix.sigaction(std.posix.SIG.TERM, &sigaction, null);

    // DB
    const db_path_z = try allocator.dupeZ(u8, cfg.db_path);
    defer allocator.free(db_path_z);
    var db = try sqlite.Db.open(db_path_z, allocator);
    defer db.deinit();
    try db.criarEsquema();
    global_db = &db;

    // Cache de IA
    var cache_ia = cache_ia_m.CacheIA.init(allocator);
    defer cache_ia.deinit();
    global_cache_ia = &cache_ia;

    // Cache de mensagens (deduplicação)
    var cache_mensagens = cache_mens_m.CacheMensagens.init(allocator);
    defer cache_mensagens.deinit();
    global_cache_mensagens = &cache_mensagens;

    // Telemetria — thread de background
    var telemetria = telemetria_m.Telemetria.init(.{}, &cache_ia, &cache_mensagens);
    const tel_thread = try telemetria.iniciar();
    tel_thread.detach();
    defer telemetria.parar();

    // Thread de retry de mensagens pendentes
    const retry_thread = try std.Thread.spawn(.{}, monitorarTransacoes, .{});
    retry_thread.detach();

    // Provedores de IA
    var ia_gemini: ResilienteGemini = undefined;
    var ia_openrouter: ResilienteOpenRouter = undefined;
    var fila_gemini: fila_midia.FilaMidia(ResilienteGemini) = undefined;
    var fila_openrouter: fila_midia.FilaMidia(ResilienteOpenRouter) = undefined;

    if (cfg.gemini_api_key.len > 0) {
        std.log.info("I.A Engine: [Gemini] Registrado.", .{});
        const base_ia = gemini.GeminiAdapter{
            .config    = .{ .api_key = cfg.gemini_api_key },
            .allocator = allocator,
        };
        ia_gemini       = ResilienteGemini.init(base_ia, .{});
        global_ia_gemini = &ia_gemini;

        fila_gemini = try fila_midia.FilaMidia(ResilienteGemini).init(allocator, 4, &ia_gemini, enviarWhatsApp, reagirWhatsApp);
        global_fila_gemini = &fila_gemini;
    }

    if (cfg.openrouter_api_key.len > 0) {
        std.log.info("I.A Engine: [OpenRouter] Registrado.", .{});
        const base_ia = openrouter.OpenRouterAdapter{
            .config    = .{ .api_key = cfg.openrouter_api_key },
            .allocator = allocator,
        };
        ia_openrouter       = ResilienteOpenRouter.init(base_ia, .{});
        global_ia_openrouter = &ia_openrouter;

        fila_openrouter = try fila_midia.FilaMidia(ResilienteOpenRouter).init(allocator, 4, &ia_openrouter, enviarWhatsApp, reagirWhatsApp);
        global_fila_openrouter = &fila_openrouter;
    }

    if (global_ia_gemini == null and global_ia_openrouter == null) {
        std.log.err("Nenhum provedor de IA configurado. Forneça GEMINI_API_KEY ou OPENROUTER_API_KEY.", .{});
        return error.SemChavesAPI;
    }

    try http.startServer(cfg.port, .{
        .mensagem = processarHttpMensagem,
        .ack      = processarHttpAck,
        .grupo    = processarHttpGrupo,
    }, &global_encerrando, allocator);

    std.log.info("Amélie encerrada.", .{});
}
