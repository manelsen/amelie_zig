// infra/openrouter.zig
// Adapter OpenRouter — HTTP puro, sem retry, sem circuit breaker.
// Segue o mesmo duck-typing de GeminiAdapter. Compatível com Resiliente(T).
//
// Usa API OpenAI Chat Completions compatível do OpenRouter.
//

const std = @import("std");

pub const MODELO_PADRAO = "google/gemini-2.5-flash-lite"; // Example fallback model on OpenRouter
pub const URL_BASE = "https://openrouter.ai/api/v1/chat/completions";

pub const OpenRouterConfig = struct {
    api_key: []const u8,
    modelo: []const u8 = MODELO_PADRAO,
    temperature: f64 = 0.9,
    max_tokens: u32 = 1024,
};

pub const ErroOpenRouter = error{
    HttpError,
    RespostaVazia,
    JsonMalformado,
    UrlInvalida,
};

pub const OpenRouterAdapter = struct {
    config: OpenRouterConfig,
    allocator: std.mem.Allocator,

    pub fn init(config: OpenRouterConfig, allocator: std.mem.Allocator) OpenRouterAdapter {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn gerarTexto(
        self: *OpenRouterAdapter,
        prompt: []const u8,
        system_prompt: ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const body = try montarBodyTexto(self.config, prompt, system_prompt, allocator);
        defer allocator.free(body);

        return self.chamarAPI(body, allocator);
    }

    pub fn processarMidia(
        self: *OpenRouterAdapter,
        dados: []const u8,
        mimetype: []const u8,
        prompt: ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        if (std.mem.eql(u8, mimetype, "application/pdf") or std.mem.eql(u8, mimetype, "application/vnd.openxmlformats-officedocument.wordprocessingml.document") or std.mem.eql(u8, mimetype, "text/csv")) {
            return allocator.dupe(u8, "⚠️ O provedor atual (OpenRouter) foca em visão computacional e não suporta processamento de documentos complexos (PDF/Doc/CSV). Mude para o provedor Gemini.");
        }

        const p = prompt orelse promptPadraoPorMime(mimetype);
        const body = try montarBodyMidia(self.config, dados, mimetype, p, allocator);
        defer allocator.free(body);

        return self.chamarAPI(body, allocator);
    }

    fn chamarAPI(self: *OpenRouterAdapter, body: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const uri = std.Uri.parse(URL_BASE) catch return ErroOpenRouter.UrlInvalida;

        var auth_header = std.ArrayListUnmanaged(u8){};
        try auth_header.writer(allocator).print("Bearer {s}", .{self.config.api_key});
        defer auth_header.deinit(allocator);

        // Required headers for standard OpenRouter identification
        const referer_hdr = std.http.Header{ .name = "HTTP-Referer", .value = "https://github.com/VoidCanvas/Amelie" };
        const title_hdr = std.http.Header{ .name = "X-Title", .value = "Amelie (Zig)" };
        const auth_hdr = std.http.Header{ .name = "Authorization", .value = auth_header.items };

        var req = try client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = &.{ auth_hdr, referer_hdr, title_hdr },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };

        var payload_stream = try req.sendBodyUnflushed(&.{});
        try payload_stream.writer.writeAll(body);
        try payload_stream.end();
        try req.connection.?.flush();

        var redirect_buf: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        if (response.head.status != .ok) {
            var err_reader = response.reader(&.{});
            var err_buf = std.ArrayListUnmanaged(u8){};
            defer err_buf.deinit(allocator);
            var transfer_buffer: [8192]u8 = undefined;
            while (true) {
                const len = try err_reader.readSliceShort(&transfer_buffer);
                if (len == 0) break;
                try err_buf.appendSlice(allocator, transfer_buffer[0..len]);
            }
            std.log.err("OpenRouter API Error: Status {d} - {s}", .{ @intFromEnum(response.head.status), err_buf.items });
            return ErroOpenRouter.HttpError;
        }

        var reader = response.reader(&.{});
        var res_buf = std.ArrayListUnmanaged(u8){};
        defer res_buf.deinit(allocator);

        var transfer_buffer: [8192]u8 = undefined;
        while (true) {
            const len = try reader.readSliceShort(&transfer_buffer);
            if (len == 0) break;
            try res_buf.appendSlice(allocator, transfer_buffer[0..len]);
        }

        return extrairTextoResposta(res_buf.items, allocator);
    }
};

fn montarBodyTexto(
    cfg: OpenRouterConfig,
    prompt: []const u8,
    system_prompt: ?[]const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    const w = buf.writer(allocator);

    try w.print("{{\"model\":", .{});
    try escreverStringJson(w, cfg.modelo);

    try w.print(",\"temperature\":{d},\"messages\":[", .{cfg.temperature});

    if (system_prompt) |sp| {
        try w.writeAll("{\"role\":\"system\",\"content\":");
        try escreverStringJson(w, sp);
        try w.writeAll("},");
    }

    try w.writeAll("{\"role\":\"user\",\"content\":");
    try escreverStringJson(w, prompt);
    try w.writeAll("}]}");

    return buf.toOwnedSlice(allocator);
}

fn montarBodyMidia(
    cfg: OpenRouterConfig,
    dados: []const u8,
    mimetype: []const u8,
    prompt: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    const w = buf.writer(allocator);

    try w.print("{{\"model\":", .{});
    try escreverStringJson(w, cfg.modelo);

    try w.print(",\"temperature\":{d},\"messages\":[", .{cfg.temperature});

    try w.writeAll("{\"role\":\"user\",\"content\":[");

    try w.writeAll("{\"type\":\"text\",\"text\":");
    try escreverStringJson(w, prompt);
    try w.writeAll("},");

    try w.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try w.writeAll(mimetype);
    try w.writeAll(";base64,");
    try w.writeAll(dados);
    try w.writeAll("\"}}");

    try w.writeAll("]}]}");

    return buf.toOwnedSlice(allocator);
}

fn extrairTextoResposta(json_raw: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_raw, .{ .ignore_unknown_fields = true }) catch return ErroOpenRouter.JsonMalformado;
    defer parsed.deinit();

    if (parsed.value != .object) return ErroOpenRouter.JsonMalformado;

    const choices = parsed.value.object.get("choices") orelse return ErroOpenRouter.RespostaVazia;
    if (choices != .array or choices.array.items.len == 0) return ErroOpenRouter.RespostaVazia;

    const message = choices.array.items[0].object.get("message") orelse return ErroOpenRouter.RespostaVazia;
    if (message != .object) return ErroOpenRouter.RespostaVazia;

    const content = message.object.get("content") orelse return ErroOpenRouter.RespostaVazia;

    if (content != .string) return ErroOpenRouter.RespostaVazia;

    return allocator.dupe(u8, limparResposta(content.string));
}

fn limparResposta(texto: []const u8) []const u8 {
    var t = std.mem.trim(u8, texto, " \t\n\r");
    inline for (.{ "amélie:", "amelie:", "Amélie:", "Amelie:" }) |prefix| {
        if (std.mem.startsWith(u8, t, prefix)) {
            t = std.mem.trim(u8, t[prefix.len..], " ");
            break;
        }
    }
    return t;
}

fn promptPadraoPorMime(mimetype: []const u8) []const u8 {
    if (std.mem.startsWith(u8, mimetype, "image/")) return "Descreva esta imagem.";
    if (std.mem.startsWith(u8, mimetype, "audio/")) return "Transcreva este áudio.";
    if (std.mem.startsWith(u8, mimetype, "video/")) return "Descreva este vídeo.";
    return "Analise este documento.";
}

fn escreverStringJson(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

test "montarBodyTexto: openrouter" {
    const alloc = std.testing.allocator;
    const cfg = OpenRouterConfig{ .api_key = "x", .temperature = 0.5 };
    const body = try montarBodyTexto(cfg, "olá openai compat", "sys prompt", alloc);
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sys prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "olá openai compat") != null);
}

test "montarBodyMidia: openrouter vision" {
    const alloc = std.testing.allocator;
    const cfg = OpenRouterConfig{ .api_key = "x", .modelo = "vision-model" };
    const body = try montarBodyMidia(cfg, "base64data==", "image/jpeg", "Descreva.", alloc);
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "vision-model") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image_url") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data:image/jpeg;base64,base64data==") != null);
}
