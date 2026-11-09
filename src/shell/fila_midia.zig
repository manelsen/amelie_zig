// shell/fila_midia.zig
// Fila de processamento assíncrono para mídia.
// Consome urls, baixa o conteúdo, processa via IA e envia a resposta.

const std = @import("std");
const msg_m = @import("../dominio/mensagem.zig");

/// Returns a comptime-specialised media processing queue. IA must expose `processarMidia`.
pub fn FilaMidia(comptime IA: type) type {
    return struct {
        /// A single media processing job. All string fields are heap-allocated copies owned by the queue.
        pub const Tarefa = struct {
            chat_id: []const u8,
            msg_id: []const u8,
            midia: msg_m.Conteudo.Midia,
            system_prompt: ?[]const u8,
        };

        allocator: std.mem.Allocator,
        ia: *IA,
        enviarFn: *const fn ([]const u8, []const u8) void,
        reagirFn: *const fn ([]const u8, []const u8, []const u8) void,

        mutex: std.Thread.Mutex,
        cond: std.Thread.Condition,
        tarefas: std.ArrayListUnmanaged(Tarefa),
        threads: []std.Thread,
        encerrando: bool,

        const Self = @This();

        /// Allocates the queue on the heap and spawns `num_threads` worker threads. The caller must eventually call `deinit`.
        pub fn init(
            allocator: std.mem.Allocator,
            num_threads: usize,
            ia: *IA,
            enviarFn: *const fn ([]const u8, []const u8) void,
            reagirFn: *const fn ([]const u8, []const u8, []const u8) void,
        ) !*Self {
            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .ia = ia,
                .enviarFn = enviarFn,
                .reagirFn = reagirFn,
                .mutex = .{},
                .cond = .{},
                .tarefas = .{},
                .threads = try allocator.alloc(std.Thread, num_threads),
                .encerrando = false,
            };

            for (self.threads) |*t| {
                t.* = try std.Thread.spawn(.{}, worker, .{self});
            }

            return self;
        }

        /// Signals workers to stop, joins all threads, and frees all pending tasks and the queue itself.
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

        /// Deep-copies the task data, appends it to the queue, emits a ⏳ reaction, and wakes a worker thread.
        pub fn enfileirar(self: *Self, chat_id: []const u8, msg_id: []const u8, midia: msg_m.Conteudo.Midia, sp: ?[]const u8) !void {
            var sp_dup: ?[]const u8 = null;
            if (sp) |s| sp_dup = try self.allocator.dupe(u8, s);

            const t = Tarefa{
                .chat_id = try self.allocator.dupe(u8, chat_id),
                .msg_id = try self.allocator.dupe(u8, msg_id),
                .midia = .{
                    .tipo = midia.tipo,
                    .url = try self.allocator.dupe(u8, midia.url),
                    .caption = if (midia.caption) |c| try self.allocator.dupe(u8, c) else null,
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

        /// Removes all pending tasks for `chat_id` without processing them.
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

        /// Frees all heap-allocated fields of a `Tarefa`.
        fn liberarTarefa(allocator: std.mem.Allocator, t: Tarefa) void {
            allocator.free(t.chat_id);
            allocator.free(t.msg_id);
            allocator.free(t.midia.url);
            if (t.midia.caption) |c| allocator.free(c);
            if (t.midia.mimetype) |m| allocator.free(m);
            if (t.midia.filename) |f| allocator.free(f);
            if (t.system_prompt) |s| allocator.free(s);
        }

        /// Blocking worker loop: dequeues a task, processes it, reacts with 🆗 or ❌, then loops.
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

        /// Downloads the media, base-64 encodes it, resolves the final MIME type, calls the IA, and sends the result.
        fn processarTarefa(self: *Self, t: Tarefa, temp_alloc: std.mem.Allocator) !void {
            const payload = try baixarPayload(t.midia.url, temp_alloc);

            const b64_len = std.base64.standard.Encoder.calcSize(payload.len);
            const b64 = try temp_alloc.alloc(u8, b64_len);
            _ = std.base64.standard.Encoder.encode(b64, payload);

            const mime = resolverMime(t.midia);

            std.log.info("Processando mídia para {s}: mime={s}, url={s}", .{ t.chat_id, mime, t.midia.url });

            const resposta = try self.ia.processarMidia(b64, mime, t.midia.caption, temp_alloc);

            self.enviarFn(t.chat_id, resposta);
        }

        /// Downloads the raw bytes at `url` using `std.http.Client`. Returns `error.DownloadFailed` on non-200 status.
        fn baixarPayload(url: []const u8, temp_alloc: std.mem.Allocator) ![]const u8 {
            var client = std.http.Client{ .allocator = temp_alloc };
            defer client.deinit();

            const uri = try std.Uri.parse(url);

            var body_writer = std.Io.Writer.Allocating.init(temp_alloc);
            defer body_writer.deinit();
            const result = try client.fetch(.{
                .location = .{ .uri = uri },
                .headers = .{ .accept_encoding = .{ .override = "identity" } },
                .response_writer = &body_writer.writer,
            });

            if (result.status != .ok) return error.DownloadFailed;
            return try body_writer.toOwnedSlice();
        }
    };
}

// ---------------------------------------------------------------------------
// Helpers de módulo
// ---------------------------------------------------------------------------

/// Resolves the effective MIME type for a media item.
/// Strips codec parameters (e.g. `"audio/ogg; codecs=opus"` → `"audio/ogg"`).
/// Falls back to extension-based detection when the type is `application/octet-stream`.
fn resolverMime(midia: msg_m.Conteudo.Midia) []const u8 {
    var mime = midia.mimetype orelse "application/octet-stream";

    if (std.mem.indexOfScalar(u8, mime, ';')) |idx| {
        mime = mime[0..idx];
    }

    if (std.mem.eql(u8, mime, "application/octet-stream")) {
        const MimeMap = std.StaticStringMap([]const u8).initComptime(.{
            .{ ".jpg", "image/jpeg" },
            .{ ".jpeg", "image/jpeg" },
            .{ ".png", "image/png" },
            .{ ".pdf", "application/pdf" },
            .{ ".ogg", "audio/ogg" },
            .{ ".mp3", "audio/mpeg" },
            .{ ".mp4", "video/mp4" },
            .{ ".txt", "text/plain" },
            .{ ".csv", "text/csv" },
            .{ ".docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
            .{ ".xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
            .{ ".pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
        });

        const alvo = midia.filename orelse midia.url;
        if (std.mem.lastIndexOfScalar(u8, alvo, '.')) |idx| {
            if (MimeMap.get(alvo[idx..])) |m| mime = m;
        }
    }

    return mime;
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
        _ = _d;
        _ = _m;
        _ = _p;
        self.chamadas += 1;
        return alloc.dupe(u8, self.resposta);
    }
};

const Captura = struct {
    chat_id: []const u8 = "",
    texto: []const u8 = "",
    msg_id: []const u8 = "",
    emoji: []const u8 = "",
    _tbuf: [1024]u8 = undefined,
    var instancia: Captura = .{};

    fn reset() void {
        instancia = .{};
    }

    fn enviar(c: []const u8, t: []const u8) void {
        const tl = @min(t.len, instancia._tbuf.len);
        @memcpy(instancia._tbuf[0..tl], t[0..tl]);
        instancia.texto = instancia._tbuf[0..tl];
        instancia.chat_id = c;
    }

    fn reagir(c: []const u8, m: []const u8, e: []const u8) void {
        instancia.chat_id = c;
        instancia.msg_id = m;
        instancia.emoji = e;
    }
};

test "FilaMidia: limparFilas remove apenas o chat_id correto" {
    var ia = MockIA{};
    const FM = FilaMidia(MockIA);
    const fm = try FM.init(testing.allocator, 0, &ia, Captura.enviar, Captura.reagir);
    defer fm.deinit();

    try fm.enfileirar("chat_a", "m1", .{ .tipo = .imagem, .url = "url" }, null);
    try fm.enfileirar("chat_b", "m2", .{ .tipo = .imagem, .url = "url" }, null);
    try fm.enfileirar("chat_a", "m3", .{ .tipo = .imagem, .url = "url" }, null);

    fm.limparFilas("chat_a");

    try testing.expectEqual(@as(usize, 1), fm.tarefas.items.len);
    try testing.expectEqualStrings("chat_b", fm.tarefas.items[0].chat_id);
}

test "FilaMidia: processarTarefa strip codec suffix do mimetype" {
    var server = try TestMediaServer.start();
    defer server.deinit();

    var ia = MockIA{ .resposta = "ok codec strip" };
    const FM = FilaMidia(MockIA);
    const fm = try FM.init(testing.allocator, 0, &ia, Captura.enviar, Captura.reagir);
    defer fm.deinit();

    Captura.reset();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/a.ogg", .{server.port});
    defer testing.allocator.free(url);

    // mimetype with codec suffix — processarTarefa must strip "; codecs=opus" before passing to IA
    const tarefa = FM.Tarefa{
        .chat_id = "chat_codec",
        .msg_id = "msg_codec",
        .midia = .{
            .tipo = .audio,
            .url = try testing.allocator.dupe(u8, url),
            .mimetype = "audio/ogg; codecs=opus",
        },
        .system_prompt = null,
    };
    defer testing.allocator.free(tarefa.midia.url);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try fm.processarTarefa(tarefa, arena.allocator());
    try testing.expectEqual(@as(usize, 1), ia.chamadas);
}

test "FilaMidia: processarTarefa detecta mimetype por extensão quando octet-stream" {
    var server = try TestMediaServer.start();
    defer server.deinit();

    var ia = MockIA{ .resposta = "ok ext detect" };
    const FM = FilaMidia(MockIA);
    const fm = try FM.init(testing.allocator, 0, &ia, Captura.enviar, Captura.reagir);
    defer fm.deinit();

    Captura.reset();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/doc.pdf", .{server.port});
    defer testing.allocator.free(url);

    // mimetype = application/octet-stream → must fall back to extension ".pdf"
    const tarefa = FM.Tarefa{
        .chat_id = "chat_ext",
        .msg_id = "msg_ext",
        .midia = .{
            .tipo = .documento,
            .url = try testing.allocator.dupe(u8, url),
            .mimetype = "application/octet-stream",
        },
        .system_prompt = null,
    };
    defer testing.allocator.free(tarefa.midia.url);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try fm.processarTarefa(tarefa, arena.allocator());
    try testing.expectEqual(@as(usize, 1), ia.chamadas);
    try testing.expectEqualStrings("ok ext detect", Captura.instancia.texto);
}

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

const TestMediaServer = struct {
    listener: std.net.Server,
    thread: std.Thread,
    port: u16,

    fn start() !TestMediaServer {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        const listener = try addr.listen(.{ .reuse_address = true });
        const port = listener.listen_address.in.getPort();
        const thread = try std.Thread.spawn(.{}, run, .{listener});
        return .{ .listener = listener, .thread = thread, .port = port };
    }

    fn deinit(self: *TestMediaServer) void {
        self.thread.join();
        self.listener.deinit();
    }

    fn run(listener_arg: std.net.Server) void {
        var listener = listener_arg;
        var conn = listener.accept() catch return;
        defer conn.stream.close();

        var io_buf: [1024]u8 = undefined;
        _ = conn.stream.read(&io_buf) catch return;

        const body = "midia-teste";
        const response = std.fmt.bufPrint(
            &io_buf,
            "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: image/jpeg\r\nConnection: close\r\n\r\n{s}",
            .{ body.len, body },
        ) catch return;
        conn.stream.writeAll(response) catch return;
    }
};

test "FilaMidia: baixa mídia por HTTP local sem panicar" {
    var server = try TestMediaServer.start();
    defer server.deinit();

    var ia = MockIA{ .resposta = "Midia HTTP ok" };
    const FM = FilaMidia(MockIA);
    const fm = try FM.init(testing.allocator, 0, &ia, Captura.enviar, Captura.reagir);
    defer fm.deinit();

    Captura.reset();

    const url = try std.fmt.allocPrint(testing.allocator, "http://127.0.0.1:{d}/media.jpg", .{server.port});
    defer testing.allocator.free(url);

    const tarefa = FM.Tarefa{
        .chat_id = "chat_http",
        .msg_id = "msg_http",
        .midia = .{
            .tipo = .imagem,
            .url = try testing.allocator.dupe(u8, url),
            .mimetype = "image/jpeg",
        },
        .system_prompt = null,
    };
    defer testing.allocator.free(tarefa.midia.url);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try fm.processarTarefa(tarefa, arena.allocator());

    try testing.expectEqual(@as(usize, 1), ia.chamadas);
    try testing.expectEqualStrings("chat_http", Captura.instancia.chat_id);
    try testing.expectEqualStrings("Midia HTTP ok", Captura.instancia.texto);
}
