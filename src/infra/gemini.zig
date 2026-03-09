// infra/gemini.zig
// Adapter Gemini — HTTP puro, sem retry, sem circuit breaker.
// Resiliência é responsabilidade de Resiliente(GeminiAdapter).
//
// API Gemini usada:
//   POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
//
// Zig 0.15: std.http.Client com novo padrão de Reader/Writer.

const std      = @import("std");
const file_api = @import("google_file_api.zig");

pub const MODELO_PADRAO = "gemini-2.5-flash-lite";
pub const URL_BASE      = "https://generativelanguage.googleapis.com/v1beta/models/";

pub const GeminiConfig = struct {
    api_key:          []const u8,
    modelo:           []const u8 = MODELO_PADRAO,
    temperature:      f64        = 0.9,
    top_k:            u32        = 1,
    top_p:            f64        = 0.95,
    max_tokens:       u32        = 1024,
};

pub const ErroGemini = error{
    HttpError,
    RespostaVazia,
    ConteudoBloqueado,
    JsonMalformado,
    UrlInvalida,
};

// ---------------------------------------------------------------------------
// GeminiAdapter — duck-type compatível com Resiliente(T)
// ---------------------------------------------------------------------------

pub const GeminiAdapter = struct {
    config:    GeminiConfig,
    allocator: std.mem.Allocator,

    pub fn init(config: GeminiConfig, allocator: std.mem.Allocator) GeminiAdapter {
        return .{ .config = config, .allocator = allocator };
    }

    /// Gera texto a partir de prompt + system prompt opcional.
    /// Retorna slice alocado — caller é responsável por liberar.
    pub fn gerarTexto(
        self:          *GeminiAdapter,
        prompt:        []const u8,
        system_prompt: ?[]const u8,
        allocator:     std.mem.Allocator,
    ) ![]const u8 {
        const body = try montarBodyTexto(
            self.config, prompt, system_prompt, allocator,
        );
        defer allocator.free(body);

        return self.chamarAPI(body, allocator);
    }

    /// Processa mídia inline (imagem, áudio, documento) ou vídeo via File API.
    /// `dados` é base64 do conteúdo; `mimetype` ex: "image/jpeg" ou "video/mp4".
    pub fn processarMidia(
        self:      *GeminiAdapter,
        dados:     []const u8,   // base64
        mimetype:  []const u8,
        prompt:    ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        // Vídeo: decodifica base64 → bytes crus → File API (não suporta inline)
        if (std.mem.startsWith(u8, mimetype, "video/")) {
            const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(dados);
            const decoded = try allocator.alloc(u8, decoded_len);
            defer allocator.free(decoded);
            try std.base64.standard.Decoder.decode(decoded, dados);
            return self.processarVideoViaFileApi(decoded, mimetype, prompt, allocator);
        }

        const p = prompt orelse promptPadraoPorMime(mimetype);
        const body = try montarBodyMidia(self.config, dados, mimetype, p, allocator);
        defer allocator.free(body);

        return self.chamarAPI(body, allocator);
    }

    fn processarVideoViaFileApi(
        self:      *GeminiAdapter,
        dados_raw: []const u8,  // bytes crus (não base64)
        mimetype:  []const u8,
        prompt:    ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        // 1. Upload → obtém fileUri
        const file_uri = try file_api.uploadArquivo(
            self.config.api_key, dados_raw, mimetype, allocator,
        );
        defer allocator.free(file_uri);

        // 2. Poll até ACTIVE (max 2 min)
        const file_name = file_api.nomeDeUri(file_uri);
        try file_api.aguardarAtivo(self.config.api_key, file_name, allocator);

        // 3. Limpeza best-effort após uso
        defer file_api.deletarArquivo(self.config.api_key, file_name, allocator);

        // 4. Gera resposta referenciando o arquivo
        const p = prompt orelse "Descreva este vídeo.";
        const body = try montarBodyVideoFileApi(self.config, file_uri, mimetype, p, allocator);
        defer allocator.free(body);

        return self.chamarAPI(body, allocator);
    }

    // --- HTTP ---

    fn chamarAPI(self: *GeminiAdapter, body: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const url_str = try std.fmt.allocPrint(
            allocator,
            "{s}{s}:generateContent?key={s}",
            .{ URL_BASE, self.config.modelo, self.config.api_key },
        );
        defer allocator.free(url_str);

        const uri = std.Uri.parse(url_str) catch return ErroGemini.UrlInvalida;

        var req = try client.request(.POST, uri, .{
            .headers = .{ 
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" }
            }
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
            std.log.err("Gemini API Error: Status {d} - {s}", .{ @intFromEnum(response.head.status), err_buf.items });
            return ErroGemini.HttpError;
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

// ---------------------------------------------------------------------------
// Montagem do JSON de request
// ---------------------------------------------------------------------------

fn montarBodyTexto(
    cfg:           GeminiConfig,
    prompt:        []const u8,
    system_prompt: ?[]const u8,
    allocator:     std.mem.Allocator,
) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    const w = buf.writer(allocator);

    try w.writeAll("{");

    if (system_prompt) |sp| {
        try w.writeAll("\"system_instruction\":{\"parts\":[{\"text\":");
        try escreverStringJson(w, sp);
        try w.writeAll("}]},");
    }

    try w.print(
        "\"generationConfig\":{{\"temperature\":{d},\"topK\":{d},\"topP\":{d},\"maxOutputTokens\":{d}}},",
        .{ cfg.temperature, cfg.top_k, cfg.top_p, cfg.max_tokens },
    );

    try w.writeAll("\"contents\":[{\"parts\":[{\"text\":");
    try escreverStringJson(w, prompt);
    try w.writeAll("}]}]}");

    return buf.toOwnedSlice(allocator);
}

fn montarBodyMidia(
    cfg:      GeminiConfig,
    dados:    []const u8,
    mimetype: []const u8,
    prompt:   []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    const w = buf.writer(allocator);

    try w.print(
        "{{\"generationConfig\":{{\"temperature\":{d},\"topK\":{d},\"topP\":{d},\"maxOutputTokens\":{d}}},",
        .{ cfg.temperature, cfg.top_k, cfg.top_p, cfg.max_tokens },
    );
    try w.writeAll("\"contents\":[{\"parts\":[");
    try w.writeAll("{\"inlineData\":{\"mimeType\":");
    try escreverStringJson(w, mimetype);
    try w.writeAll(",\"data\":");
    try escreverStringJson(w, dados);
    try w.writeAll("}},{\"text\":");
    try escreverStringJson(w, prompt);
    try w.writeAll("}]}]}");

    return buf.toOwnedSlice(allocator);
}

fn montarBodyVideoFileApi(
    cfg:      GeminiConfig,
    file_uri: []const u8,
    mimetype: []const u8,
    prompt:   []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    const w = buf.writer(allocator);

    try w.print(
        "{{\"generationConfig\":{{\"temperature\":{d},\"topK\":{d},\"topP\":{d},\"maxOutputTokens\":{d}}},",
        .{ cfg.temperature, cfg.top_k, cfg.top_p, cfg.max_tokens },
    );
    try w.writeAll("\"contents\":[{\"parts\":[");
    try w.writeAll("{\"fileData\":{\"mimeType\":");
    try escreverStringJson(w, mimetype);
    try w.writeAll(",\"fileUri\":");
    try escreverStringJson(w, file_uri);
    try w.writeAll("}},{\"text\":");
    try escreverStringJson(w, prompt);
    try w.writeAll("}]}]}");

    return buf.toOwnedSlice(allocator);
}

/// Extrai o texto de `candidates[0].content.parts[0].text` da resposta Gemini.
fn extrairTextoResposta(json_raw: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const parsed = std.json.parseFromSlice(
        std.json.Value, allocator, json_raw, .{},
    ) catch return ErroGemini.JsonMalformado;
    defer parsed.deinit();

    // Verifica bloqueio de segurança
    if (parsed.value == .object) {
        if (parsed.value.object.get("promptFeedback")) |pf| {
            if (pf == .object and pf.object.get("blockReason") != null) {
                return ErroGemini.ConteudoBloqueado;
            }
        }
    }

    // Navega: candidates[0].content.parts[0].text
    const candidates = parsed.value.object.get("candidates") orelse return ErroGemini.RespostaVazia;
    if (candidates != .array or candidates.array.items.len == 0) return ErroGemini.RespostaVazia;

    const content = candidates.array.items[0].object.get("content") orelse return ErroGemini.RespostaVazia;
    const parts   = content.object.get("parts") orelse return ErroGemini.RespostaVazia;
    if (parts != .array or parts.array.items.len == 0) return ErroGemini.RespostaVazia;

    const text = parts.array.items[0].object.get("text") orelse return ErroGemini.RespostaVazia;
    if (text != .string) return ErroGemini.RespostaVazia;

    return allocator.dupe(u8, limparResposta(text.string));
}

/// Remove prefixos "amélie:" / "amelie:" e espaços extras.
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
    if (std.mem.startsWith(u8, mimetype, "image/"))       return "Descreva esta imagem.";
    if (std.mem.startsWith(u8, mimetype, "audio/"))       return "Transcreva este áudio.";
    if (std.mem.startsWith(u8, mimetype, "video/"))       return "Descreva este vídeo.";
    return "Analise este documento.";
}

// ---------------------------------------------------------------------------
// Escrita segura de string JSON (escapa caracteres especiais)
// ---------------------------------------------------------------------------

fn escreverStringJson(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"'  => try w.writeAll("\\\""),
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
// Testes — sem HTTP real; testamos as funções puras
// ---------------------------------------------------------------------------

test "montarBodyTexto: sem system prompt" {
    const alloc = std.testing.allocator;
    const cfg = GeminiConfig{ .api_key = "x", .temperature = 0.5, .top_k = 2, .top_p = 0.8, .max_tokens = 512 };
    const body = try montarBodyTexto(cfg, "olá mundo", null, alloc);
    defer alloc.free(body);

    // Deve conter a temperatura configurada e o prompt
    try std.testing.expect(std.mem.indexOf(u8, body, "\"temperature\":0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "olá mundo") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "system_instruction") == null);
}

test "montarBodyTexto: com system prompt" {
    const alloc = std.testing.allocator;
    const cfg = GeminiConfig{ .api_key = "x" };
    const body = try montarBodyTexto(cfg, "prompt", "Seja conciso.", alloc);
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "system_instruction") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Seja conciso.") != null);
}

test "montarBodyMidia: estrutura correta" {
    const alloc = std.testing.allocator;
    const cfg = GeminiConfig{ .api_key = "x" };
    const body = try montarBodyMidia(cfg, "base64data==", "image/jpeg", "Descreva.", alloc);
    defer alloc.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "inlineData") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image/jpeg") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "base64data==") != null);
}

test "escreverStringJson: escapa caracteres especiais" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);

    try escreverStringJson(buf.writer(alloc), "linha1\nlinha2\t\"aspas\"\\barra");
    const result = buf.items;

    try std.testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\\") != null);
}

test "limparResposta: remove prefixo amélie:" {
    try std.testing.expectEqualStrings("Olá!", limparResposta("amélie: Olá!"));
    try std.testing.expectEqualStrings("Olá!", limparResposta("amelie: Olá!"));
    try std.testing.expectEqualStrings("Olá!", limparResposta("Amélie: Olá!"));
    try std.testing.expectEqualStrings("Texto normal.", limparResposta("Texto normal."));
}

test "limparResposta: remove espaços" {
    try std.testing.expectEqualStrings("ok", limparResposta("  ok  "));
    try std.testing.expectEqualStrings("ok", limparResposta("\n ok \n"));
}

test "extrairTextoResposta: payload Gemini válido" {
    const alloc = std.testing.allocator;
    const json =
        \\{"candidates":[{"content":{"parts":[{"text":"Olá, como posso ajudar?"}],"role":"model"},"finishReason":"STOP"}]}
    ;
    const texto = try extrairTextoResposta(json, alloc);
    defer alloc.free(texto);
    try std.testing.expectEqualStrings("Olá, como posso ajudar?", texto);
}

test "extrairTextoResposta: conteúdo bloqueado → erro" {
    const alloc = std.testing.allocator;
    const json =
        \\{"promptFeedback":{"blockReason":"SAFETY"},"candidates":[]}
    ;
    const result = extrairTextoResposta(json, alloc);
    try std.testing.expectError(ErroGemini.ConteudoBloqueado, result);
}

test "extrairTextoResposta: candidates vazio → erro" {
    const alloc = std.testing.allocator;
    const json = \\{"candidates":[]}
    ;
    const result = extrairTextoResposta(json, alloc);
    try std.testing.expectError(ErroGemini.RespostaVazia, result);
}

test "promptPadraoPorMime: retorna prompt correto por tipo" {
    try std.testing.expectEqualStrings("Descreva esta imagem.", promptPadraoPorMime("image/jpeg"));
    try std.testing.expectEqualStrings("Transcreva este áudio.", promptPadraoPorMime("audio/ogg"));
    try std.testing.expectEqualStrings("Descreva este vídeo.", promptPadraoPorMime("video/mp4"));
    try std.testing.expectEqualStrings("Analise este documento.", promptPadraoPorMime("application/pdf"));
}
