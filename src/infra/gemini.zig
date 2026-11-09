// infra/gemini.zig
// Adapter Gemini — HTTP puro, sem retry, sem circuit breaker.
// Resiliência é responsabilidade de Resiliente(GeminiAdapter).
//
// API Gemini usada:
//   POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
//
// Zig 0.15: std.http.Client com novo padrão de Reader/Writer.

const std = @import("std");
const http_fetch = @import("http_fetch.zig");
const file_api = @import("google_file_api.zig");
const json_util = @import("json_util.zig");
const builtin = @import("builtin");

pub const MODELO_PADRAO = "gemini-2.5-flash-lite";
pub const URL_BASE = "https://generativelanguage.googleapis.com/v1beta/models/";

pub const GeminiConfig = struct {
    api_key: []const u8,
    modelo: []const u8 = MODELO_PADRAO,
    temperature: f64 = 0.9,
    top_k: u32 = 1,
    top_p: f64 = 0.95,
    max_tokens: u32 = 1024,
};

pub const ErroGemini = error{
    HttpError,
    RespostaVazia,
    ConteudoBloqueado,
    MidiaNaoSuportada,
    ArgumentoInvalido,
    JsonMalformado,
    UrlInvalida,
};

// ---------------------------------------------------------------------------
// GeminiAdapter — duck-type compatível com Resiliente(T)
// ---------------------------------------------------------------------------

pub const GeminiAdapter = struct {
    config: GeminiConfig,
    allocator: std.mem.Allocator,

    pub fn init(config: GeminiConfig, allocator: std.mem.Allocator) GeminiAdapter {
        return .{ .config = config, .allocator = allocator };
    }

    /// Gera texto a partir de prompt + system prompt opcional.
    /// Retorna slice alocado — caller é responsável por liberar.
    pub fn gerarTexto(
        self: *GeminiAdapter,
        prompt: []const u8,
        system_prompt: ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const body = try montarBodyTexto(
            self.config,
            prompt,
            system_prompt,
            allocator,
        );
        defer allocator.free(body);

        return self.chamarAPI(body, allocator);
    }

    /// Processa mídia inline (imagem, áudio, documento) ou vídeo via File API.
    /// `dados` é base64 do conteúdo; `mimetype` ex: "image/jpeg" ou "video/mp4".
    pub fn processarMidia(
        self: *GeminiAdapter,
        dados: []const u8, // base64
        mimetype: []const u8,
        prompt: ?[]const u8,
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

        if (mimeEhDocumentoViaFileApi(mimetype)) {
            const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(dados);
            const decoded = try allocator.alloc(u8, decoded_len);
            defer allocator.free(decoded);
            try std.base64.standard.Decoder.decode(decoded, dados);
            return self.processarDocumentoViaFileApi(decoded, mimetype, prompt, allocator);
        }

        if (!mimeEhInlineSuportado(mimetype)) {
            return allocator.dupe(u8, "⚠️ Tipo de midia nao suportado nesta integracao do Gemini.");
        }

        const p = prompt orelse promptPadraoPorMime(mimetype);
        const body = try montarBodyMidia(self.config, dados, mimetype, p, allocator);
        defer allocator.free(body);

        return self.chamarAPI(body, allocator);
    }

    fn processarVideoViaFileApi(
        self: *GeminiAdapter,
        dados_raw: []const u8, // bytes crus (não base64)
        mimetype: []const u8,
        prompt: ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        // 1. Upload → obtém fileUri
        const arquivo = try file_api.uploadArquivoInfo(
            self.config.api_key,
            dados_raw,
            mimetype,
            allocator,
        );
        defer allocator.free(arquivo.name);
        defer allocator.free(arquivo.uri);

        // 2. Poll até ACTIVE (max 2 min)
        try file_api.aguardarAtivo(self.config.api_key, arquivo.name, allocator);

        // 3. Limpeza best-effort após uso
        defer file_api.deletarArquivo(self.config.api_key, arquivo.name, allocator);

        // 4. Gera resposta referenciando o arquivo
        const p = prompt orelse "Descreva este vídeo.";
        const body = try montarBodyVideoFileApi(self.config, arquivo.uri, mimetype, p, allocator);
        defer allocator.free(body);

        return self.chamarAPI(body, allocator);
    }

    fn processarDocumentoViaFileApi(
        self: *GeminiAdapter,
        dados_raw: []const u8,
        mimetype: []const u8,
        prompt: ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        if (ehDocx(mimetype)) {
            return self.processarDocxComFallback(dados_raw, mimetype, prompt, allocator);
        }

        const arquivo = try file_api.uploadArquivoInfo(
            self.config.api_key,
            dados_raw,
            mimetype,
            allocator,
        );
        defer allocator.free(arquivo.name);
        defer allocator.free(arquivo.uri);

        try file_api.aguardarAtivo(self.config.api_key, arquivo.name, allocator);
        defer file_api.deletarArquivo(self.config.api_key, arquivo.name, allocator);

        const p = prompt orelse "Analise este documento.";
        const body = try montarBodyVideoFileApi(self.config, arquivo.uri, mimetype, p, allocator);
        defer allocator.free(body);

        return self.chamarAPI(body, allocator);
    }

    fn processarDocxComFallback(
        self: *GeminiAdapter,
        dados_raw: []const u8,
        mimetype: []const u8,
        prompt: ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const tentativa = self.processarDocumentoViaFileApiSemFallback(dados_raw, mimetype, prompt, allocator);
        return tentativa catch |err| switch (err) {
            ErroGemini.MidiaNaoSuportada => {
                const texto = try extrairTextoDocx(dados_raw, allocator);
                defer allocator.free(texto);
                if (texto.len == 0) return ErroGemini.RespostaVazia;

                const prompt_texto = try montarPromptDocumentoTexto(prompt orelse "Analise este documento.", texto, allocator);
                defer allocator.free(prompt_texto);
                return self.gerarTexto(prompt_texto, null, allocator);
            },
            else => err,
        };
    }

    fn processarDocumentoViaFileApiSemFallback(
        self: *GeminiAdapter,
        dados_raw: []const u8,
        mimetype: []const u8,
        prompt: ?[]const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const arquivo = try file_api.uploadArquivoInfo(
            self.config.api_key,
            dados_raw,
            mimetype,
            allocator,
        );
        defer allocator.free(arquivo.name);
        defer allocator.free(arquivo.uri);

        try file_api.aguardarAtivo(self.config.api_key, arquivo.name, allocator);
        defer file_api.deletarArquivo(self.config.api_key, arquivo.name, allocator);

        const p = prompt orelse "Analise este documento.";
        const body = try montarBodyVideoFileApi(self.config, arquivo.uri, mimetype, p, allocator);
        defer allocator.free(body);

        return self.chamarAPI(body, allocator);
    }

    // --- HTTP ---

    fn chamarAPI(self: *GeminiAdapter, body: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const url_str = try std.fmt.allocPrint(
            allocator,
            "{s}{s}:generateContent?key={s}",
            .{ URL_BASE, self.config.modelo, self.config.api_key },
        );
        defer allocator.free(url_str);

        const uri = std.Uri.parse(url_str) catch return ErroGemini.UrlInvalida;

        const result = try http_fetch.fetch(allocator, .{ .uri = uri }, .{
            .method = .POST,
            .payload = body,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        });
        defer allocator.free(result.body);

        if (result.status == .bad_request) {
            if (std.mem.indexOf(u8, result.body, "Unsupported MIME type") != null)
                return ErroGemini.MidiaNaoSuportada;
            return ErroGemini.ArgumentoInvalido;
        }

        if (result.status != .ok) {
            std.log.err("Gemini API Error: Status {d} - {s}", .{ @intFromEnum(result.status), result.body });
            return ErroGemini.HttpError;
        }

        return extrairTextoResposta(result.body, allocator);
    }
};

// ---------------------------------------------------------------------------
// Montagem do JSON de request
// ---------------------------------------------------------------------------

/// Serialises a text-only generateContent request body. `system_prompt` is emitted as `system_instruction` when present.
fn montarBodyTexto(
    cfg: GeminiConfig,
    prompt: []const u8,
    system_prompt: ?[]const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    const w = buf.writer(allocator);

    try w.writeAll("{");

    if (system_prompt) |sp| {
        try w.writeAll("\"system_instruction\":{\"parts\":[{\"text\":");
        try json_util.escreverStringJson(w, sp);
        try w.writeAll("}]},");
    }

    try w.print(
        "\"generationConfig\":{{\"temperature\":{d},\"topK\":{d},\"topP\":{d},\"maxOutputTokens\":{d}}},",
        .{ cfg.temperature, cfg.top_k, cfg.top_p, cfg.max_tokens },
    );

    try w.writeAll("\"contents\":[{\"parts\":[{\"text\":");
    try json_util.escreverStringJson(w, prompt);
    try w.writeAll("}]}]}");

    return buf.toOwnedSlice(allocator);
}

/// Serialises a generateContent request with an inline base-64 media part followed by a text prompt.
fn montarBodyMidia(
    cfg: GeminiConfig,
    dados: []const u8,
    mimetype: []const u8,
    prompt: []const u8,
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
    try json_util.escreverStringJson(w, mimetype);
    try w.writeAll(",\"data\":");
    try json_util.escreverStringJson(w, dados);
    try w.writeAll("}},{\"text\":");
    try json_util.escreverStringJson(w, prompt);
    try w.writeAll("}]}]}");

    return buf.toOwnedSlice(allocator);
}

/// Serialises a generateContent request referencing a previously uploaded file via its URI (`fileData`). Used for video and large documents.
fn montarBodyVideoFileApi(
    cfg: GeminiConfig,
    file_uri: []const u8,
    mimetype: []const u8,
    prompt: []const u8,
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
    try json_util.escreverStringJson(w, mimetype);
    try w.writeAll(",\"fileUri\":");
    try json_util.escreverStringJson(w, file_uri);
    try w.writeAll("}},{\"text\":");
    try json_util.escreverStringJson(w, prompt);
    try w.writeAll("}]}]}");

    return buf.toOwnedSlice(allocator);
}

/// Navigates `candidates[0].content.parts[0].text` in the Gemini JSON response. Returns `ConteudoBloqueado` when `promptFeedback.blockReason` is present.
fn extrairTextoResposta(json_raw: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_raw,
        .{},
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
    const parts = content.object.get("parts") orelse return ErroGemini.RespostaVazia;
    if (parts != .array or parts.array.items.len == 0) return ErroGemini.RespostaVazia;

    const text = parts.array.items[0].object.get("text") orelse return ErroGemini.RespostaVazia;
    if (text != .string) return ErroGemini.RespostaVazia;

    return allocator.dupe(u8, json_util.limparResposta(text.string));
}

/// Returns a sensible default prompt string for a given MIME type.
fn promptPadraoPorMime(mimetype: []const u8) []const u8 {
    if (std.mem.startsWith(u8, mimetype, "image/")) return "Descreva esta imagem.";
    if (std.mem.startsWith(u8, mimetype, "audio/")) return "Transcreva este áudio.";
    if (std.mem.startsWith(u8, mimetype, "video/")) return "Descreva este vídeo.";
    return "Analise este documento.";
}

/// Returns true for MIME types Gemini accepts as inline `inlineData` (image/*, audio/*). Video and documents must go through the File API.
fn mimeEhInlineSuportado(mimetype: []const u8) bool {
    return std.mem.startsWith(u8, mimetype, "image/") or
        std.mem.startsWith(u8, mimetype, "audio/");
}

/// Returns true for document MIME types (PDF, Office formats, CSV) that must be uploaded via the File API.
fn mimeEhDocumentoViaFileApi(mimetype: []const u8) bool {
    return std.mem.eql(u8, mimetype, "application/pdf") or
        std.mem.eql(u8, mimetype, "application/vnd.openxmlformats-officedocument.wordprocessingml.document") or
        std.mem.eql(u8, mimetype, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") or
        std.mem.eql(u8, mimetype, "application/vnd.openxmlformats-officedocument.presentationml.presentation") or
        std.mem.eql(u8, mimetype, "text/csv");
}

/// Returns true only for the OOXML Word document MIME type.
fn ehDocx(mimetype: []const u8) bool {
    return std.mem.eql(u8, mimetype, "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
}

/// Concatenates the user prompt with extracted document text, capped at 24 000 characters.
fn montarPromptDocumentoTexto(prompt_base: []const u8, texto: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const limite = @min(texto.len, 24_000);
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\nConteudo extraido do documento:\n{s}",
        .{ prompt_base, texto[0..limite] },
    );
}

/// Writes `dados_raw` to a temporary file and extracts plain text via `unzip` + XML parsing.
fn extrairTextoDocx(dados_raw: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var nome_buf: [128]u8 = undefined;
    const nome = try std.fmt.bufPrint(&nome_buf, "/tmp/amelie-docx-{d}.docx", .{std.time.nanoTimestamp()});

    {
        const arquivo = try std.fs.createFileAbsolute(nome, .{ .truncate = true });
        defer arquivo.close();
        try arquivo.writeAll(dados_raw);
    }
    defer std.fs.deleteFileAbsolute(nome) catch {};

    return extrairXmlDocxComoTexto(std.fs.cwd(), nome, allocator);
}

/// Runs `unzip -p <path> word/document.xml` and strips XML tags, expanding common entities.
fn extrairXmlDocxComoTexto(dir: std.fs.Dir, caminho: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const argv = if (builtin.os.tag == .windows)
        &.{ "unzip.exe", "-p", caminho, "word/document.xml" }
    else
        &.{ "unzip", "-p", caminho, "word/document.xml" };

    const resultado = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd_dir = dir,
        .max_output_bytes = 8 * 1024 * 1024,
    });
    defer allocator.free(resultado.stdout);
    defer allocator.free(resultado.stderr);

    if (resultado.term != .Exited or resultado.term.Exited != 0 or resultado.stdout.len == 0) {
        return ErroGemini.MidiaNaoSuportada;
    }

    return extrairTextoDeXmlWord(resultado.stdout, allocator);
}

/// Parses raw `word/document.xml` bytes into readable plain text. Inserts newlines at paragraph boundaries and expands XML entities.
fn extrairTextoDeXmlWord(xml: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    var i: usize = 0;
    var dentro_tag = false;
    while (i < xml.len) : (i += 1) {
        const c = xml[i];
        if (c == '<') {
            dentro_tag = true;
            if (std.mem.startsWith(u8, xml[i..], "<w:p") or std.mem.startsWith(u8, xml[i..], "</w:p")) {
                try out.append(allocator, '\n');
            } else if (std.mem.startsWith(u8, xml[i..], "<w:tab")) {
                try out.append(allocator, '\t');
            }
            continue;
        }
        if (c == '>') {
            dentro_tag = false;
            continue;
        }
        if (dentro_tag) continue;

        if (c == '&') {
            if (std.mem.startsWith(u8, xml[i..], "&amp;")) {
                try out.append(allocator, '&');
                i += "&amp;".len - 1;
                continue;
            }
            if (std.mem.startsWith(u8, xml[i..], "&lt;")) {
                try out.append(allocator, '<');
                i += "&lt;".len - 1;
                continue;
            }
            if (std.mem.startsWith(u8, xml[i..], "&gt;")) {
                try out.append(allocator, '>');
                i += "&gt;".len - 1;
                continue;
            }
            if (std.mem.startsWith(u8, xml[i..], "&quot;")) {
                try out.append(allocator, '"');
                i += "&quot;".len - 1;
                continue;
            }
            if (std.mem.startsWith(u8, xml[i..], "&apos;")) {
                try out.append(allocator, '\'');
                i += "&apos;".len - 1;
                continue;
            }
        }

        try out.append(allocator, c);
    }

    const bruto = try out.toOwnedSlice(allocator);
    defer allocator.free(bruto);
    return normalizarEspacosDocumento(bruto, allocator);
}

/// Collapses consecutive whitespace characters and trims leading/trailing whitespace. Multiple newlines collapse to one; multiple spaces collapse to one.
fn normalizarEspacosDocumento(texto: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    var ultimo_foi_espaco = false;
    var ultimo_foi_quebra = false;
    for (texto) |c| {
        switch (c) {
            ' ', '\t', '\r' => {
                if (!ultimo_foi_espaco and !ultimo_foi_quebra) {
                    try out.append(allocator, ' ');
                    ultimo_foi_espaco = true;
                }
            },
            '\n' => {
                if (!ultimo_foi_quebra) {
                    try out.append(allocator, '\n');
                    ultimo_foi_quebra = true;
                }
                ultimo_foi_espaco = false;
            },
            else => {
                try out.append(allocator, c);
                ultimo_foi_espaco = false;
                ultimo_foi_quebra = false;
            },
        }
    }

    const bruto = try out.toOwnedSlice(allocator);
    errdefer allocator.free(bruto);

    const inicio = std.mem.indexOfNone(u8, bruto, " \n\t\r") orelse bruto.len;
    const fim = std.mem.lastIndexOfNone(u8, bruto, " \n\t\r");
    if (fim == null or inicio >= bruto.len) {
        allocator.free(bruto);
        return allocator.dupe(u8, "");
    }

    const slice = bruto[inicio .. fim.? + 1];
    const normalizado = try allocator.dupe(u8, slice);
    allocator.free(bruto);
    return normalizado;
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
    const json =
        \\{"candidates":[]}
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

test "extrairTextoDeXmlWord: converte XML do DOCX em texto legivel" {
    const alloc = std.testing.allocator;
    const xml =
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<w:document><w:body><w:p><w:r><w:t>Ola</w:t></w:r></w:p><w:p><w:r><w:t>Mundo &amp; Teste</w:t></w:r></w:p></w:body></w:document>
    ;

    const texto = try extrairTextoDeXmlWord(xml, alloc);
    defer alloc.free(texto);

    try std.testing.expectEqualStrings("Ola\nMundo & Teste", texto);
}

test "montarPromptDocumentoTexto: limita e inclui cabecalho" {
    const alloc = std.testing.allocator;
    const prompt = try montarPromptDocumentoTexto("Analise.", "abc", alloc);
    defer alloc.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Analise.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Conteudo extraido do documento:") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "abc") != null);
}

// ---------------------------------------------------------------------------
// montarBodyVideoFileApi — invariante crítico (roteamento de vídeo/doc via File API)
// ---------------------------------------------------------------------------

test "montarBodyVideoFileApi: usa fileData não inlineData" {
    const alloc = std.testing.allocator;
    const cfg = GeminiConfig{ .api_key = "x" };
    const uri = "https://generativelanguage.googleapis.com/v1beta/files/abc123";
    const body = try montarBodyVideoFileApi(cfg, uri, "video/mp4", "Descreva.", alloc);
    defer alloc.free(body);

    // Deve usar fileData (não inlineData) — sem isso a API retorna 400
    try std.testing.expect(std.mem.indexOf(u8, body, "fileData") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "inlineData") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "fileUri") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "video/mp4") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Descreva.") != null);
}

test "montarBodyVideoFileApi: produz JSON válido" {
    const alloc = std.testing.allocator;
    const cfg = GeminiConfig{ .api_key = "x" };
    const body = try montarBodyVideoFileApi(cfg, "https://example.com/files/vid1", "video/mp4", "Prompt.", alloc);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
}

test "montarBodyVideoFileApi: prompt com caracteres especiais é escapado" {
    const alloc = std.testing.allocator;
    const cfg = GeminiConfig{ .api_key = "x" };
    const body = try montarBodyVideoFileApi(cfg, "https://x.com/f", "video/mp4", "Diga \"olá\".", alloc);
    defer alloc.free(body);
    // JSON deve ser válido mesmo com aspas no prompt
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
}

// ---------------------------------------------------------------------------
// JSON validity dos body builders
// ---------------------------------------------------------------------------

test "montarBodyTexto: produz JSON válido com caracteres especiais" {
    const alloc = std.testing.allocator;
    const cfg = GeminiConfig{ .api_key = "x" };
    const body = try montarBodyTexto(cfg, "texto com \"aspas\" e\nnewline", "system: \"role\"", alloc);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
}

test "montarBodyMidia: produz JSON válido" {
    const alloc = std.testing.allocator;
    const cfg = GeminiConfig{ .api_key = "x" };
    const body = try montarBodyMidia(cfg, "base64data==", "image/jpeg", "Descreva.", alloc);
    defer alloc.free(body);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
}

// ---------------------------------------------------------------------------
// Classificação de MIME types — invariantes de roteamento
// ---------------------------------------------------------------------------

test "mimeEhInlineSuportado: imagem e áudio são inline; vídeo e doc não" {
    try std.testing.expect(mimeEhInlineSuportado("image/jpeg"));
    try std.testing.expect(mimeEhInlineSuportado("image/png"));
    try std.testing.expect(mimeEhInlineSuportado("image/webp"));
    try std.testing.expect(mimeEhInlineSuportado("audio/ogg"));
    try std.testing.expect(mimeEhInlineSuportado("audio/mpeg"));
    try std.testing.expect(!mimeEhInlineSuportado("video/mp4"));
    try std.testing.expect(!mimeEhInlineSuportado("application/pdf"));
    try std.testing.expect(!mimeEhInlineSuportado("text/plain"));
    try std.testing.expect(!mimeEhInlineSuportado(""));
}

test "mimeEhDocumentoViaFileApi: PDF, DOCX, XLSX, PPTX, CSV → true; outros → false" {
    try std.testing.expect(mimeEhDocumentoViaFileApi("application/pdf"));
    try std.testing.expect(mimeEhDocumentoViaFileApi("application/vnd.openxmlformats-officedocument.wordprocessingml.document"));
    try std.testing.expect(mimeEhDocumentoViaFileApi("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"));
    try std.testing.expect(mimeEhDocumentoViaFileApi("application/vnd.openxmlformats-officedocument.presentationml.presentation"));
    try std.testing.expect(mimeEhDocumentoViaFileApi("text/csv"));
    try std.testing.expect(!mimeEhDocumentoViaFileApi("image/jpeg"));
    try std.testing.expect(!mimeEhDocumentoViaFileApi("video/mp4"));
    try std.testing.expect(!mimeEhDocumentoViaFileApi("text/plain"));
}

test "ehDocx: só DOCX mimetype exato → true" {
    try std.testing.expect(ehDocx("application/vnd.openxmlformats-officedocument.wordprocessingml.document"));
    try std.testing.expect(!ehDocx("application/pdf"));
    try std.testing.expect(!ehDocx("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"));
    try std.testing.expect(!ehDocx(""));
}

// ---------------------------------------------------------------------------
// normalizarEspacosDocumento — invariantes de limpeza de texto
// ---------------------------------------------------------------------------

test "normalizarEspacosDocumento: colapsa múltiplos espaços em um" {
    const alloc = std.testing.allocator;
    const r = try normalizarEspacosDocumento("  hello   world  ", alloc);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("hello world", r);
}

test "normalizarEspacosDocumento: colapsa múltiplas quebras de linha" {
    const alloc = std.testing.allocator;
    const r = try normalizarEspacosDocumento("linha1\n\n\nlinha2", alloc);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("linha1\nlinha2", r);
}

test "normalizarEspacosDocumento: espaços antes de quebra colapsam para um espaço" {
    const alloc = std.testing.allocator;
    // múltiplos espaços antes de \n → colapsa para exatamente um espaço + \n
    const r = try normalizarEspacosDocumento("a   \n   b", alloc);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("a \nb", r);
}

test "normalizarEspacosDocumento: string só de espaços → vazia" {
    const alloc = std.testing.allocator;
    const r = try normalizarEspacosDocumento("   \n\t  \r  ", alloc);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("", r);
}

test "normalizarEspacosDocumento: string vazia → vazia" {
    const alloc = std.testing.allocator;
    const r = try normalizarEspacosDocumento("", alloc);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("", r);
}

// ---------------------------------------------------------------------------
// extrairTextoResposta — bordas de erro
// ---------------------------------------------------------------------------

test "extrairTextoResposta: JSON malformado → JsonMalformado" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        ErroGemini.JsonMalformado,
        extrairTextoResposta("{malformed json", alloc),
    );
}

test "extrairTextoResposta: sem campo candidates → RespostaVazia" {
    const alloc = std.testing.allocator;
    const json =
        \\{"model":"gemini"}
    ;
    try std.testing.expectError(
        ErroGemini.RespostaVazia,
        extrairTextoResposta(json, alloc),
    );
}

test "extrairTextoResposta: parts vazio → RespostaVazia" {
    const alloc = std.testing.allocator;
    const json =
        \\{"candidates":[{"content":{"parts":[],"role":"model"}}]}
    ;
    try std.testing.expectError(
        ErroGemini.RespostaVazia,
        extrairTextoResposta(json, alloc),
    );
}

test "extrairTextoResposta: part sem campo text → RespostaVazia" {
    const alloc = std.testing.allocator;
    const json =
        \\{"candidates":[{"content":{"parts":[{"inlineData":{}}],"role":"model"}}]}
    ;
    try std.testing.expectError(
        ErroGemini.RespostaVazia,
        extrairTextoResposta(json, alloc),
    );
}
