// shell/fila_midia.zig
// Fila de processamento assíncrono para mídia.
// Consome urls, baixa o conteúdo, processa via IA e envia a resposta.

const std = @import("std");
const msg_m = @import("../dominio/mensagem.zig");

pub fn FilaMidia(comptime IA: type) type {
    return struct {
        pub const Tarefa = struct {
            chat_id:       []const u8,
            msg_id:        []const u8,
            midia:         msg_m.Conteudo.Midia,
            system_prompt: ?[]const u8,
        };

        allocator: std.mem.Allocator,
        ia:        *IA,
        enviarFn:  *const fn ([]const u8, []const u8) void,
        reagirFn:  *const fn ([]const u8, []const u8, []const u8) void,

        mutex:      std.Thread.Mutex,
        cond:       std.Thread.Condition,
        tarefas:    std.ArrayListUnmanaged(Tarefa),
        threads:    []std.Thread,
        encerrando: bool,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            num_threads: usize,
            ia: *IA,
            enviarFn: *const fn ([]const u8, []const u8) void,
            reagirFn: *const fn ([]const u8, []const u8, []const u8) void,
        ) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .allocator  = allocator,
                .ia         = ia,
                .enviarFn   = enviarFn,
                .reagirFn   = reagirFn,
                .mutex      = .{},
                .cond       = .{},
                .tarefas    = .{},
                .threads    = try allocator.alloc(std.Thread, num_threads),
                .encerrando = false,
            };

            for (self.threads) |*t| {
                t.* = try std.Thread.spawn(.{}, worker, .{self});
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.encerrando = true;
                self.cond.broadcast();
            }

            for (self.threads) |t| {
                t.join();
            }

            self.allocator.free(self.threads);
            for (self.tarefas.items) |t| {
                liberarTarefa(self.allocator, t);
            }
            self.tarefas.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn enfileirar(self: *Self, chat_id: []const u8, msg_id: []const u8, midia: msg_m.Conteudo.Midia, sp: ?[]const u8) !void {
            var sp_dup: ?[]const u8 = null;
            if (sp) |s| sp_dup = try self.allocator.dupe(u8, s);

            const t = Tarefa{
                .chat_id = try self.allocator.dupe(u8, chat_id),
                .msg_id  = try self.allocator.dupe(u8, msg_id),
                .midia = .{
                    .tipo     = midia.tipo,
                    .url      = try self.allocator.dupe(u8, midia.url),
                    .caption  = if (midia.caption) |c| try self.allocator.dupe(u8, c) else null,
                    .mimetype = if (midia.mimetype) |m| try self.allocator.dupe(u8, m) else null,
                    .filename = if (midia.filename) |f| try self.allocator.dupe(u8, f) else null,
                },
                .system_prompt = sp_dup,
            };

            self.mutex.lock();
            defer self.mutex.unlock();
            try self.tarefas.append(self.allocator, t);
            self.reagirFn(chat_id, msg_id, "⏳");
            self.cond.signal();
        }

        pub fn limparFilas(self: *Self, chat_id: []const u8) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            var i: usize = 0;
            while (i < self.tarefas.items.len) {
                if (std.mem.eql(u8, self.tarefas.items[i].chat_id, chat_id)) {
                    liberarTarefa(self.allocator, self.tarefas.items[i]);
                    _ = self.tarefas.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        fn liberarTarefa(allocator: std.mem.Allocator, t: Tarefa) void {
            allocator.free(t.chat_id);
            allocator.free(t.msg_id);
            allocator.free(t.midia.url);
            if (t.midia.caption) |c| allocator.free(c);
            if (t.midia.mimetype) |m| allocator.free(m);
            if (t.midia.filename) |f| allocator.free(f);
            if (t.system_prompt) |s| allocator.free(s);
        }

        fn worker(self: *Self) void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            while (true) {
                _ = arena.reset(.retain_capacity);
                var t_opt: ?Tarefa = null;
                {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    while (self.tarefas.items.len == 0 and !self.encerrando) {
                        self.cond.wait(&self.mutex);
                    }

                    if (self.encerrando and self.tarefas.items.len == 0) {
                        return;
                    }

                    t_opt = self.tarefas.orderedRemove(0);
                }

                if (t_opt) |tarefa| {
                    if (self.processarTarefa(tarefa, arena.allocator())) |_| {
                        self.reagirFn(tarefa.chat_id, tarefa.msg_id, "🆗");
                    } else |err| {
                        std.log.err("Erro processando mídia para {s}: {}", .{ tarefa.chat_id, err });
                        self.reagirFn(tarefa.chat_id, tarefa.msg_id, "❌");
                    }
                    liberarTarefa(self.allocator, tarefa);
                }
            }
        }

        fn processarTarefa(self: *Self, t: Tarefa, temp_alloc: std.mem.Allocator) !void {
            var client = std.http.Client{ .allocator = temp_alloc };
            defer client.deinit();

            const uri = try std.Uri.parse(t.midia.url);

            var req = try client.request(.GET, uri, .{
                .headers = .{ .accept_encoding = .{ .override = "identity" } }
            });
            defer req.deinit();

            try req.sendBodiless();

            var head_buf: [8192]u8 = undefined;
            var head = try req.receiveHead(&head_buf);

            if (head.head.status != .ok) {
                return error.DownloadFailed;
            }

            // Lê o corpo inteiro de forma simples e robusta no Zig 0.15
            var body_list = std.ArrayListUnmanaged(u8){};
            defer body_list.deinit(temp_alloc);
            
            var buf: [8192]u8 = undefined;
            // No Zig 0.15, o Reader é uma struct que possui o método readSliceShort().
            var reader = head.reader(&.{});
            while (true) {
                const n = try reader.readSliceShort(&buf);
                if (n == 0) break;
                try body_list.appendSlice(temp_alloc, buf[0..n]);
            }
            
            const payload = body_list.items;

            const b64_len = std.base64.standard.Encoder.calcSize(payload.len);
            const b64 = try temp_alloc.alloc(u8, b64_len);
            _ = std.base64.standard.Encoder.encode(b64, payload);

            var mime = t.midia.mimetype orelse "application/octet-stream";

            if (std.mem.indexOfScalar(u8, mime, ';')) |idx| {
                mime = mime[0..idx];
            }

            if (std.mem.eql(u8, mime, "application/octet-stream")) {
                const MimeMap = std.StaticStringMap([]const u8).initComptime(.{
                    .{ ".jpg",   "image/jpeg" },
                    .{ ".jpeg",  "image/jpeg" },
                    .{ ".png",   "image/png" },
                    .{ ".pdf",   "application/pdf" },
                    .{ ".ogg",   "audio/ogg" },
                    .{ ".mp3",   "audio/mpeg" },
                    .{ ".mp4",   "video/mp4" },
                    .{ ".txt",   "text/plain" },
                    .{ ".csv",   "text/csv" },
                    .{ ".docx",  "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
                    .{ ".xlsx",  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
                    .{ ".pptx",  "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
                });

                const alvo = t.midia.filename orelse t.midia.url;
                if (std.mem.lastIndexOfScalar(u8, alvo, '.')) |idx| {
                    if (MimeMap.get(alvo[idx..])) |m| {
                        mime = m;
                    }
                }
            }

            std.log.info("Processando mídia para {s}: mime={s}, url={s}", .{ t.chat_id, mime, t.midia.url });

            const prompt = t.midia.caption;
            const resposta = try self.ia.processarMidia(b64, mime, prompt, temp_alloc);

            self.enviarFn(t.chat_id, resposta);
        }
    };
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

const MockIA = struct {
    resposta: []const u8 = "Mock Midia",
    chamadas: usize = 0,
    pub fn processarMidia(
        self: *MockIA,
        _d: []const u8,
        _m: []const u8,
        _p: ?[]const u8,
        alloc: std.mem.Allocator,
    ) ![]const u8 {
        _ = _d; _ = _m; _ = _p;
        self.chamadas += 1;
        return alloc.dupe(u8, self.resposta);
    }
};

const Captura = struct {
    chat_id: []const u8 = "",
    texto:   []const u8 = "",
    msg_id:  []const u8 = "",
    emoji:   []const u8 = "",
    _tbuf:   [1024]u8   = undefined,
    var instancia: Captura = .{};

    fn reset() void { instancia = .{}; }

    fn enviar(c: []const u8, t: []const u8) void {
        const tl = @min(t.len, instancia._tbuf.len);
        @memcpy(instancia._tbuf[0..tl], t[0..tl]);
        instancia.texto = instancia._tbuf[0..tl];
        instancia.chat_id = c;
    }

    fn reagir(c: []const u8, m: []const u8, e: []const u8) void {
        instancia.chat_id = c;
        instancia.msg_id  = m;
        instancia.emoji   = e;
    }
};

test "FilaMidia: ciclo básico de enfileirar e limpar" {
    var ia = MockIA{};
    const FM = FilaMidia(MockIA);
    const fm = try FM.init(testing.allocator, 1, &ia, Captura.enviar, Captura.reagir);
    defer fm.deinit();

    try fm.enfileirar("chat1", "msg1", .{ .tipo = .imagem, .url = "url" }, null);
    try testing.expectEqual(@as(usize, 1), fm.tarefas.items.len);

    fm.limparFilas("chat1");
    try testing.expectEqual(@as(usize, 0), fm.tarefas.items.len);
}
