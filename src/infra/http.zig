// infra/http.zig
// Servidor HTTP/1.1 mínimo (Zig 0.15) + parsing do webhook Baileys → Mensagem.
//
// Responsabilidades:
//   - Aceitar conexões TCP, ler body do POST /webhook
//   - Parsear JSON Baileys → Mensagem (domínio)
//   - Chamar handler(Mensagem) → responder 200/400
//
// Fora do escopo aqui: autenticação, TLS, keep-alive.

const std    = @import("std");
const msg_m  = @import("../dominio/mensagem.zig");
const cmd_m  = @import("../dominio/comando.zig");

pub const Mensagem = msg_m.Mensagem;
pub const Conteudo  = msg_m.Conteudo;
pub const TipoMidia = msg_m.TipoMidia;
pub const Comando   = cmd_m.Comando;

// ---------------------------------------------------------------------------
// Estrutura do payload Baileys (campo `message` é Value por ser polimórfico)
// ---------------------------------------------------------------------------

const WebhookPayload = struct {
    key: Key,
    messageTimestamp: ?i64          = null,
    pushName:         ?[]const u8   = null,
    message:          ?std.json.Value = null,

    const Key = struct {
        remoteJid:   []const u8,
        fromMe:      bool,
        id:          []const u8,
        participant: ?[]const u8 = null,  // grupo: JID do remetente
    };
};

// ---------------------------------------------------------------------------
// Erros
// ---------------------------------------------------------------------------

pub const ErroWebhook = error{
    JsonInvalido,
    CampoObrigatorioAusente,
    TipoMensagemDesconhecido,
};

// ---------------------------------------------------------------------------
// parsearMensagem — puro exceto pelo alocador (std.json aloca internamente)
// ---------------------------------------------------------------------------

/// Converte JSON raw do Baileys → Mensagem de domínio.
/// Caller: chame `parsed.deinit()` para liberar memória do json.
pub fn parsearMensagem(
    allocator: std.mem.Allocator,
    json_raw:  []const u8,
) !struct { msg: Mensagem, parsed: std.json.Parsed(WebhookPayload) } {
    const parsed = std.json.parseFromSlice(
        WebhookPayload,
        allocator,
        json_raw,
        .{ .ignore_unknown_fields = true },
    ) catch return ErroWebhook.JsonInvalido;

    const p = parsed.value;

    // Chat ID: remoteJid (usuário) ou remoteJid do grupo
    const chat_id  = p.key.remoteJid;
    const msg_id   = p.key.id;

    // Remetente: em grupo, o participant; caso contrário, remoteJid
    const remetente = p.key.participant orelse p.key.remoteJid;

    const em_grupo = std.mem.endsWith(u8, chat_id, "@g.us");

    const conteudo = try extrairConteudo(p);

    return .{
        .msg = Mensagem{
            .id          = msg_id,
            .chat_id     = chat_id,
            .remetente   = remetente,
            .push_name   = p.pushName,
            .conteudo    = conteudo,
            .timestamp   = p.messageTimestamp orelse 0,
            .em_grupo    = em_grupo,
            // menciona_bot e eh_admin: resolvidos pelo shell
        },
        .parsed = parsed,
    };
}

fn extrairConteudo(p: WebhookPayload) !Conteudo {
    const msg = p.message orelse return Conteudo{ .texto = "" };
    if (msg != .object) return Conteudo{ .texto = "" };
    const obj = msg.object;

    // Texto simples
    if (obj.get("conversation")) |v| {
        if (v == .string) {
            const t = v.string;
            return if (eComando(t))
                Conteudo{ .comando = Comando.parsear(t) }
            else
                Conteudo{ .texto = t };
        }
    }

    // Texto estendido (links, formatado)
    if (obj.get("extendedTextMessage")) |ext| {
        if (ext == .object) {
            if (ext.object.get("text")) |tv| {
                if (tv == .string) {
                    const t = tv.string;
                    return if (eComando(t))
                        Conteudo{ .comando = Comando.parsear(t) }
                    else
                        Conteudo{ .texto = t };
                }
            }
        }
    }

    // Imagem
    if (obj.get("imageMessage")) |im| {
        return midiaDeObj(im, .imagem);
    }

    // Áudio / PTT
    if (obj.get("audioMessage")) |am| {
        return midiaDeObj(am, .audio);
    }

    // Vídeo
    if (obj.get("videoMessage")) |vm| {
        return midiaDeObj(vm, .video);
    }

    // Documento
    if (obj.get("documentMessage")) |dm| {
        return midiaDeObj(dm, .documento);
    }

    return Conteudo{ .texto = "" };
}

fn midiaDeObj(v: std.json.Value, tipo: TipoMidia) Conteudo {
    var url:      []const u8  = "";
    var caption:  ?[]const u8 = null;
    var mimetype: ?[]const u8 = null;
    var filename: ?[]const u8 = null;

    if (v == .object) {
        if (v.object.get("url"))      |u| if (u == .string) { url      = u.string; };
        if (v.object.get("caption"))  |c| if (c == .string) { caption  = c.string; };
        if (v.object.get("mimetype")) |m| if (m == .string) { mimetype = m.string; };
        if (v.object.get("fileName")) |f| if (f == .string) { filename = f.string; };
    }

    return Conteudo{ .midia = .{
        .tipo     = tipo,
        .url      = url,
        .caption  = caption,
        .mimetype = mimetype,
        .filename = filename,
    }};
}

fn eComando(texto: []const u8) bool {
    const t = std.mem.trim(u8, texto, " \t\n\r");
    return t.len > 0 and t[0] == '.';
}

// ---------------------------------------------------------------------------
// Servidor HTTP/1.1
// ---------------------------------------------------------------------------

const RequestData = struct {
    path: []const u8,
    body: []const u8,
};

/// Estrutura agrupando todos os handlers do servidor.
pub const Handlers = struct {
    /// POST /webhook — mensagem individual Baileys
    mensagem: *const fn (Mensagem, std.mem.Allocator) []const u8,
    /// POST /webhook/ack — confirmação de entrega
    ack:      *const fn ([]const u8, std.mem.Allocator) []const u8,
    /// POST /webhook/group — evento de grupo (participante adicionado/removido)
    grupo:    ?*const fn ([]const u8, std.mem.Allocator) []const u8 = null,
};

pub fn startServer(
    port:       u16,
    handlers:   Handlers,
    encerrando: *std.atomic.Value(bool),
    allocator:  std.mem.Allocator,
) !void {
    const addr = try std.net.Address.resolveIp("0.0.0.0", port);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();

    std.log.info("Amelie escutando em :{d}", .{port});

    while (!encerrando.load(.acquire)) {
        const conn = listener.accept() catch |err| {
            if (encerrando.load(.acquire)) break;
            std.log.err("Erro ao aceitar conexão: {}", .{err});
            continue;
        };
        const t = std.Thread.spawn(.{}, handleConn, .{ conn, handlers, allocator }) catch |err| {
            std.log.err("Erro ao criar thread de conexão: {}", .{err});
            conn.stream.close();
            continue;
        };
        t.detach();
    }
}

fn handleConn(
    conn:      std.net.Server.Connection,
    handlers:  Handlers,
    allocator: std.mem.Allocator,
) void {
    defer conn.stream.close();

    var recv_buf: [16 * 1024]u8 = undefined;
    var send_buf: [4 * 1024]u8  = undefined;

    const req = readBody(conn.stream, &recv_buf) catch {
        writeResponse(conn.stream, &send_buf, 400, "bad request") catch {};
        return;
    };

    if (std.mem.eql(u8, req.path, "/webhook/ack")) {
        const resposta = handlers.ack(req.body, allocator);
        writeResponse(conn.stream, &send_buf, 200, resposta) catch {};
        return;
    }

    if (std.mem.eql(u8, req.path, "/webhook/group")) {
        if (handlers.grupo) |h| {
            const resposta = h(req.body, allocator);
            writeResponse(conn.stream, &send_buf, 200, resposta) catch {};
        } else {
            writeResponse(conn.stream, &send_buf, 200, "ok") catch {};
        }
        return;
    }

    const result = parsearMensagem(allocator, req.body) catch {
        writeResponse(conn.stream, &send_buf, 400, "json invalido") catch {};
        return;
    };
    defer result.parsed.deinit();

    const resposta = handlers.mensagem(result.msg, allocator);
    writeResponse(conn.stream, &send_buf, 200, resposta) catch {};
}

/// Lê headers HTTP e extrai o path e body.
fn readBody(stream: std.net.Stream, buf: []u8) !RequestData {
    var total: usize = 0;
    var header_end: ?usize = null;
    var req_path: []const u8 = "";

    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) break;
        total += n;

        if (header_end == null) {
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |i| {
                header_end = i + 4;
                var it = std.mem.splitSequence(u8, buf[0..i], " ");
                _ = it.next(); // METHOD
                if (it.next()) |pth| {
                    req_path = pth;
                }
            }
        }
        if (header_end != null) {
            const cl = contentLength(buf[0..header_end.?]);
            const body_start = header_end.?;
            const body_end   = body_start + (cl orelse 0);
            if (total >= body_end) return RequestData{ .path = req_path, .body = buf[body_start..body_end] };
        }
    }
    return error.IncompletaRequest;
}

fn contentLength(headers: []const u8) ?usize {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    while (it.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line["content-length:".len..], " ");
            return std.fmt.parseInt(usize, val, 10) catch null;
        }
    }
    return null;
}

fn writeResponse(stream: std.net.Stream, buf: []u8, status: u16, body: []const u8) !void {
    const text = try std.fmt.bufPrint(
        buf,
        "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ status, body.len, body },
    );
    try stream.writeAll(text);
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

test "parsearMensagem: texto simples" {
    const alloc = std.testing.allocator;
    const json =
        \\{"key":{"remoteJid":"5531@s.whatsapp.net","fromMe":false,"id":"abc"},"messageTimestamp":1700000000,"message":{"conversation":"olá mundo"}}
    ;
    const r = try parsearMensagem(alloc, json);
    defer r.parsed.deinit();

    try std.testing.expectEqualStrings("abc", r.msg.id);
    try std.testing.expectEqualStrings("5531@s.whatsapp.net", r.msg.chat_id);
    try std.testing.expect(r.msg.conteudo == .texto);
    try std.testing.expectEqualStrings("olá mundo", r.msg.conteudo.texto);
    try std.testing.expectEqual(@as(i64, 1700000000), r.msg.timestamp);
    try std.testing.expect(!r.msg.em_grupo);
}

test "parsearMensagem: comando" {
    const alloc = std.testing.allocator;
    const json =
        \\{"key":{"remoteJid":"5531@s.whatsapp.net","fromMe":false,"id":"x1"},"message":{"conversation":".ajuda"}}
    ;
    const r = try parsearMensagem(alloc, json);
    defer r.parsed.deinit();

    try std.testing.expect(r.msg.conteudo == .comando);
    try std.testing.expect(r.msg.conteudo.comando == .ajuda);
}

test "parsearMensagem: extendedTextMessage" {
    const alloc = std.testing.allocator;
    const json =
        \\{"key":{"remoteJid":"5531@s.whatsapp.net","fromMe":false,"id":"x2"},"message":{"extendedTextMessage":{"text":"texto longo"}}}
    ;
    const r = try parsearMensagem(alloc, json);
    defer r.parsed.deinit();

    try std.testing.expect(r.msg.conteudo == .texto);
    try std.testing.expectEqualStrings("texto longo", r.msg.conteudo.texto);
}

test "parsearMensagem: imagem" {
    const alloc = std.testing.allocator;
    const json =
        \\{"key":{"remoteJid":"5531@s.whatsapp.net","fromMe":false,"id":"x3"},"message":{"imageMessage":{"url":"https://x.com/img.jpg","mimetype":"image/jpeg","caption":"olha essa foto"}}}
    ;
    const r = try parsearMensagem(alloc, json);
    defer r.parsed.deinit();

    try std.testing.expect(r.msg.conteudo == .midia);
    try std.testing.expectEqual(TipoMidia.imagem, r.msg.conteudo.midia.tipo);
    try std.testing.expectEqualStrings("https://x.com/img.jpg", r.msg.conteudo.midia.url);
    try std.testing.expectEqualStrings("olha essa foto", r.msg.conteudo.midia.caption.?);
    try std.testing.expectEqualStrings("image/jpeg", r.msg.conteudo.midia.mimetype.?);
}

test "parsearMensagem: áudio" {
    const alloc = std.testing.allocator;
    const json =
        \\{"key":{"remoteJid":"5531@s.whatsapp.net","fromMe":false,"id":"x4"},"message":{"audioMessage":{"url":"https://x.com/a.ogg","mimetype":"audio/ogg; codecs=opus"}}}
    ;
    const r = try parsearMensagem(alloc, json);
    defer r.parsed.deinit();

    try std.testing.expect(r.msg.conteudo == .midia);
    try std.testing.expectEqual(TipoMidia.audio, r.msg.conteudo.midia.tipo);
}

test "parsearMensagem: vídeo" {
    const alloc = std.testing.allocator;
    const json =
        \\{"key":{"remoteJid":"5531@s.whatsapp.net","fromMe":false,"id":"x5"},"message":{"videoMessage":{"url":"https://x.com/v.mp4","mimetype":"video/mp4"}}}
    ;
    const r = try parsearMensagem(alloc, json);
    defer r.parsed.deinit();

    try std.testing.expectEqual(TipoMidia.video, r.msg.conteudo.midia.tipo);
}

test "parsearMensagem: documento" {
    const alloc = std.testing.allocator;
    const json =
        \\{"key":{"remoteJid":"5531@s.whatsapp.net","fromMe":false,"id":"x6"},"message":{"documentMessage":{"url":"https://x.com/f.pdf","mimetype":"application/pdf"}}}
    ;
    const r = try parsearMensagem(alloc, json);
    defer r.parsed.deinit();

    try std.testing.expectEqual(TipoMidia.documento, r.msg.conteudo.midia.tipo);
}

test "parsearMensagem: grupo detectado por @g.us" {
    const alloc = std.testing.allocator;
    const json =
        \\{"key":{"remoteJid":"120363@g.us","fromMe":false,"id":"g1","participant":"5531@s.whatsapp.net"},"message":{"conversation":"oi grupo"}}
    ;
    const r = try parsearMensagem(alloc, json);
    defer r.parsed.deinit();

    try std.testing.expect(r.msg.em_grupo);
    try std.testing.expectEqualStrings("120363@g.us", r.msg.chat_id);
    try std.testing.expectEqualStrings("5531@s.whatsapp.net", r.msg.remetente);
}

test "parsearMensagem: JSON inválido → erro" {
    const alloc = std.testing.allocator;
    const r = parsearMensagem(alloc, "nao eh json");
    try std.testing.expectError(ErroWebhook.JsonInvalido, r);
}

test "parsearMensagem: message ausente → texto vazio" {
    const alloc = std.testing.allocator;
    const json =
        \\{"key":{"remoteJid":"5531@s.whatsapp.net","fromMe":false,"id":"x7"}}
    ;
    const r = try parsearMensagem(alloc, json);
    defer r.parsed.deinit();

    try std.testing.expect(r.msg.conteudo == .texto);
    try std.testing.expectEqualStrings("", r.msg.conteudo.texto);
}

test "eComando: detecta ponto inicial" {
    try std.testing.expect(eComando(".ajuda"));
    try std.testing.expect(eComando(".config set x 1"));
    try std.testing.expect(!eComando("texto normal"));
    try std.testing.expect(!eComando(""));
    try std.testing.expect(eComando("  .reset  ")); // trimmed
}
