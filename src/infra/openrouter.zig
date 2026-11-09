// infra/openrouter.zig
// Adapter OpenRouter — HTTP puro, sem retry, sem circuit breaker.
// Segue o mesmo duck-typing de GeminiAdapter. Compatível com Resiliente(T).
//
// Usa API OpenAI Chat Completions compatível do OpenRouter.
//

const std = @import("std");
const http_fetch = @import("http_fetch.zig");
const json_util = @import("json_util.zig");

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

    /// Calls the OpenRouter chat completions endpoint with a text prompt and optional system prompt. Returns the assistant's reply, owned by the caller.
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

    /// Calls the OpenRouter vision endpoint with a base-64 media payload. PDF, DOCX, and CSV are rejected with a user-visible message.
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

    /// Sends `body` to the OpenRouter endpoint and extracts the response text.
    fn chamarAPI(self: *OpenRouterAdapter, body: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const uri = std.Uri.parse(URL_BASE) catch return ErroOpenRouter.UrlInvalida;

        var auth_header = std.ArrayListUnmanaged(u8){};
        try auth_header.writer(allocator).print("Bearer {s}", .{self.config.api_key});
        defer auth_header.deinit(allocator);

        // Required headers for standard OpenRouter identification
        const referer_hdr = std.http.Header{ .name = "HTTP-Referer", .value = "https://github.com/VoidCanvas/Amelie" };
        const title_hdr = std.http.Header{ .name = "X-Title", .value = "Amelie (Zig)" };
        const auth_hdr = std.http.Header{ .name = "Authorization", .value = auth_header.items };

        const result = try http_fetch.fetch(allocator, .{ .uri = uri }, .{
            .method = .POST,
            .payload = body,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = &.{ auth_hdr, referer_hdr, title_hdr },
        });
        defer allocator.free(result.body);

        if (result.status != .ok) {
            std.log.err("OpenRouter API Error: Status {d} - {s}", .{ @intFromEnum(result.status), result.body });
            return ErroOpenRouter.HttpError;
        }

        return extrairTextoResposta(result.body, allocator);
    }
};

/// Builds an OpenAI-compatible chat completions JSON request body for text-only input.
fn montarBodyTexto(
    cfg: OpenRouterConfig,
    prompt: []const u8,
    system_prompt: ?[]const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    const w = buf.writer(allocator);

    try w.print("{{\"model\":", .{});
    try json_util.escreverStringJson(w, cfg.modelo);

    try w.print(",\"temperature\":{d},\"messages\":[", .{cfg.temperature});

    if (system_prompt) |sp| {
        try w.writeAll("{\"role\":\"system\",\"content\":");
        try json_util.escreverStringJson(w, sp);
        try w.writeAll("},");
    }

    try w.writeAll("{\"role\":\"user\",\"content\":");
    try json_util.escreverStringJson(w, prompt);
    try w.writeAll("}]}");

    return buf.toOwnedSlice(allocator);
}

/// Builds an OpenAI-compatible chat completions JSON request body with a `image_url` vision part.
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
    try json_util.escreverStringJson(w, cfg.modelo);

    try w.print(",\"temperature\":{d},\"messages\":[", .{cfg.temperature});

    try w.writeAll("{\"role\":\"user\",\"content\":[");

    try w.writeAll("{\"type\":\"text\",\"text\":");
    try json_util.escreverStringJson(w, prompt);
    try w.writeAll("},");

    try w.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
    try w.writeAll(mimetype);
    try w.writeAll(";base64,");
    try w.writeAll(dados);
    try w.writeAll("\"}}");

    try w.writeAll("]}]}");

    return buf.toOwnedSlice(allocator);
}

/// Navigates `choices[0].message.content` in the OpenAI-compatible response JSON.
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

    return allocator.dupe(u8, json_util.limparResposta(content.string));
}

/// Returns a sensible default prompt string for a given MIME type.
fn promptPadraoPorMime(mimetype: []const u8) []const u8 {
    if (std.mem.startsWith(u8, mimetype, "image/")) return "Descreva esta imagem.";
    if (std.mem.startsWith(u8, mimetype, "audio/")) return "Transcreva este áudio.";
    if (std.mem.startsWith(u8, mimetype, "video/")) return "Descreva este vídeo.";
    return "Analise este documento.";
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

// ---------------------------------------------------------------------------
// montarBodyTexto — JSON válido e sem system prompt
// ---------------------------------------------------------------------------

test "montarBodyTexto: sem system prompt" {
    const alloc = std.testing.allocator;
    const cfg = OpenRouterConfig{ .api_key = "x" };
    const body = try montarBodyTexto(cfg, "mensagem", null, alloc);
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "system") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mensagem") != null);
    // Deve ser JSON válido
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
}

test "montarBodyTexto: produz JSON válido com caracteres especiais" {
    const alloc = std.testing.allocator;
    const cfg = OpenRouterConfig{ .api_key = "x" };
    const body = try montarBodyTexto(cfg, "texto com \"aspas\" e\nnewline", "role: \"system\"", alloc);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
}

// ---------------------------------------------------------------------------
// extrairTextoResposta — invariantes (formato OpenAI chat completions)
// ---------------------------------------------------------------------------

test "extrairTextoResposta: payload OpenRouter válido → texto correto" {
    const alloc = std.testing.allocator;
    const json =
        \\{"choices":[{"message":{"role":"assistant","content":"Olá, posso ajudar?"}}]}
    ;
    const texto = try extrairTextoResposta(json, alloc);
    defer alloc.free(texto);
    try std.testing.expectEqualStrings("Olá, posso ajudar?", texto);
}

test "extrairTextoResposta: remove prefixo amélie: da resposta" {
    const alloc = std.testing.allocator;
    const json =
        \\{"choices":[{"message":{"role":"assistant","content":"amelie: Resultado"}}]}
    ;
    const texto = try extrairTextoResposta(json, alloc);
    defer alloc.free(texto);
    try std.testing.expectEqualStrings("Resultado", texto);
}

test "extrairTextoResposta: choices vazio → RespostaVazia" {
    const alloc = std.testing.allocator;
    const json =
        \\{"choices":[]}
    ;
    try std.testing.expectError(ErroOpenRouter.RespostaVazia, extrairTextoResposta(json, alloc));
}

test "extrairTextoResposta: sem campo choices → RespostaVazia" {
    const alloc = std.testing.allocator;
    const json =
        \\{"model":"gpt-4","id":"abc"}
    ;
    try std.testing.expectError(ErroOpenRouter.RespostaVazia, extrairTextoResposta(json, alloc));
}

test "extrairTextoResposta: JSON malformado → JsonMalformado" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(ErroOpenRouter.JsonMalformado, extrairTextoResposta("{bad", alloc));
}
