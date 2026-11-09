// infra/google_file_api.zig
// Google Generative Language File API — upload, poll, delete.
//
// Fluxo para vídeo:
//   1. uploadArquivo()   → fileUri
//   2. aguardarAtivo()   → poll até state == "ACTIVE"
//   3. (caller usa fileUri na requisição generateContent)
//   4. deletarArquivo()  → cleanup
//
// Endpoint: https://generativelanguage.googleapis.com/upload/v1beta/files

const std = @import("std");
const http_fetch = @import("http_fetch.zig");

pub const URL_UPLOAD = "https://generativelanguage.googleapis.com/upload/v1beta/files";
pub const URL_API_BASE = "https://generativelanguage.googleapis.com/v1beta/";

const BOUNDARY = "amelie_boundary_42";

pub const ErroFileApi = error{
    HttpError,
    JsonMalformado,
    RespostaVazia,
    UrlInvalida,
    TimeoutAtivo,
};

// ---------------------------------------------------------------------------
// Estrutura da resposta de upload / poll
// ---------------------------------------------------------------------------

const FileEnvelope = struct {
    file: ?FileInfo = null,
};

const FileInfo = struct {
    name: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

pub const ArquivoSubido = struct {
    name: []u8,
    uri: []u8,
};

// ---------------------------------------------------------------------------
// uploadArquivo — multipart/related upload
// Retorna fileUri alocado no allocator fornecido. Caller libera.
// ---------------------------------------------------------------------------

/// Uploads raw bytes to the Gemini File API and returns the file URI. The URI is heap-allocated; the caller must free it. Does not wait for the file to become ACTIVE.
pub fn uploadArquivo(
    api_key: []const u8,
    dados: []const u8, // bytes crus (não base64)
    mimetype: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const arquivo = try uploadArquivoInfo(api_key, dados, mimetype, allocator);
    defer allocator.free(arquivo.name);
    return arquivo.uri;
}

/// Uploads raw bytes and returns both the file name and URI as an `ArquivoSubido`. Both slices are heap-allocated; the caller must free each.
pub fn uploadArquivoInfo(
    api_key: []const u8,
    dados: []const u8, // bytes crus (não base64)
    mimetype: []const u8,
    allocator: std.mem.Allocator,
) !ArquivoSubido {
    const metadata = "{\"file\":{\"display_name\":\"amelie_upload\"}}";

    // Monta URL com api_key
    const url_str = try std.fmt.allocPrint(
        allocator,
        "{s}?key={s}",
        .{ URL_UPLOAD, api_key },
    );
    defer allocator.free(url_str);

    const uri = std.Uri.parse(url_str) catch return ErroFileApi.UrlInvalida;

    const upload_url = try iniciarUploadResumable(
        allocator,
        uri,
        metadata,
        mimetype,
        dados.len,
    );
    defer allocator.free(upload_url);

    const upload_uri = std.Uri.parse(upload_url) catch return ErroFileApi.UrlInvalida;
    const cmd_header = std.http.Header{ .name = "X-Goog-Upload-Command", .value = "upload, finalize" };
    const offset_header = std.http.Header{ .name = "X-Goog-Upload-Offset", .value = "0" };

    const result = try http_fetch.fetch(allocator, .{ .uri = upload_uri }, .{
        .method = .POST,
        .payload = dados,
        .headers = .{
            .content_type = .{ .override = mimetype },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{ cmd_header, offset_header },
    });
    defer allocator.free(result.body);

    if (result.status != .ok and result.status != .created) {
        std.log.err("[FileAPI] Upload falhou: status={d} body={s}", .{ @intFromEnum(result.status), result.body });
        return ErroFileApi.HttpError;
    }

    return extrairArquivoSubido(result.body, allocator);
}

// ---------------------------------------------------------------------------
// aguardarAtivo — poll até state == "ACTIVE"/"SUCCEEDED" (18 tentativas × 10s = 3min)
// ---------------------------------------------------------------------------

/// Polls the file state every 10 seconds until it reaches `ACTIVE` or `SUCCEEDED`. Times out after 18 attempts (3 minutes). Returns `TimeoutAtivo` on timeout.
pub fn aguardarAtivo(
    api_key: []const u8,
    file_name: []const u8, // ex: "files/abc123"
    allocator: std.mem.Allocator,
) !void {
    const file_path = try normalizarNomeArquivo(file_name, allocator);
    defer allocator.free(file_path);
    const url_str = try std.fmt.allocPrint(
        allocator,
        "{s}{s}?key={s}",
        .{ URL_API_BASE, file_path, api_key },
    );
    defer allocator.free(url_str);

    var tentativas: u8 = 0;
    while (tentativas < 18) : (tentativas += 1) {
        std.Thread.sleep(10 * std.time.ns_per_s);

        const state = try verificarEstado(url_str, allocator);
        defer allocator.free(state);

        if (std.mem.eql(u8, state, "ACTIVE") or std.mem.eql(u8, state, "SUCCEEDED")) return;
        if (std.mem.eql(u8, state, "FAILED")) {
            std.log.err("[FileAPI] Arquivo {s} ficou em FAILED", .{file_name});
            return ErroFileApi.HttpError;
        }

        std.log.debug("[FileAPI] Arquivo {s}: estado={s}, tentativa {d}/{d}", .{ file_name, state, tentativas + 1, 18 });
    }
    return ErroFileApi.TimeoutAtivo;
}

/// GETs the file metadata and returns the current state string. Caller frees the returned slice.
fn verificarEstado(url_str: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const uri = std.Uri.parse(url_str) catch return ErroFileApi.UrlInvalida;

    const result = try http_fetch.fetch(allocator, .{ .uri = uri }, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer allocator.free(result.body);

    if (result.status != .ok) {
        std.log.err("[FileAPI] Poll falhou: status={d} body={s}", .{ @intFromEnum(result.status), result.body });
        return ErroFileApi.HttpError;
    }

    // Extrai "state" do JSON
    const parsed = std.json.parseFromSlice(
        FileInfo,
        allocator,
        result.body,
        .{ .ignore_unknown_fields = true },
    ) catch return ErroFileApi.JsonMalformado;
    defer parsed.deinit();

    const state = parsed.value.state orelse return allocator.dupe(u8, "PROCESSING");
    return allocator.dupe(u8, state);
}

// ---------------------------------------------------------------------------
// deletarArquivo — cleanup após uso. Ignora erros (best-effort).
// ---------------------------------------------------------------------------

/// Sends a DELETE request to clean up a file after use. Best-effort: errors are ignored.
pub fn deletarArquivo(
    api_key: []const u8,
    file_name: []const u8,
    allocator: std.mem.Allocator,
) void {
    const file_path = normalizarNomeArquivo(file_name, allocator) catch return;
    defer allocator.free(file_path);
    const url_str = std.fmt.allocPrint(
        allocator,
        "{s}{s}?key={s}",
        .{ URL_API_BASE, file_path, api_key },
    ) catch return;
    defer allocator.free(url_str);

    const uri = std.Uri.parse(url_str) catch return;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var req = client.request(.DELETE, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch return;
    defer req.deinit();

    req.sendBodiless() catch return;
    var head_buf: [8192]u8 = undefined;
    _ = req.receiveHead(&head_buf) catch return;
}

// ---------------------------------------------------------------------------
// Helpers privados
// ---------------------------------------------------------------------------

/// Extrai "file.uri" ou "file.name" da resposta JSON de upload.
fn extrairUri(json_raw: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const arquivo = try extrairArquivoSubido(json_raw, allocator);
    defer allocator.free(arquivo.name);
    return arquivo.uri;
}

/// Parses the upload response JSON and returns name + URI. Both slices are owned by the caller.
fn extrairArquivoSubido(json_raw: []const u8, allocator: std.mem.Allocator) !ArquivoSubido {
    const parsed = std.json.parseFromSlice(
        FileEnvelope,
        allocator,
        json_raw,
        .{ .ignore_unknown_fields = true },
    ) catch return ErroFileApi.JsonMalformado;
    defer parsed.deinit();

    const file = parsed.value.file orelse return ErroFileApi.RespostaVazia;
    const uri = file.uri orelse return ErroFileApi.RespostaVazia;
    const name = file.name orelse return ErroFileApi.RespostaVazia;
    return .{
        .name = try allocator.dupe(u8, name),
        .uri = try allocator.dupe(u8, uri),
    };
}

/// Ensures the file name has a `files/` prefix. Returns a heap-allocated copy.
fn normalizarNomeArquivo(file_name: []const u8, allocator: std.mem.Allocator) ![]u8 {
    return if (std.mem.startsWith(u8, file_name, "files/"))
        allocator.dupe(u8, file_name)
    else
        std.fmt.allocPrint(allocator, "files/{s}", .{file_name});
}

/// Initiates a resumable upload session and returns the upload URL from the `x-goog-upload-url` response header.
fn iniciarUploadResumable(
    allocator: std.mem.Allocator,
    uri: std.Uri,
    metadata: []const u8,
    mimetype: []const u8,
    content_len: usize,
) ![]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var len_buf: [32]u8 = undefined;
    const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{content_len});

    const protocol_header = std.http.Header{ .name = "X-Goog-Upload-Protocol", .value = "resumable" };
    const command_header = std.http.Header{ .name = "X-Goog-Upload-Command", .value = "start" };
    const header_len = std.http.Header{ .name = "X-Goog-Upload-Header-Content-Length", .value = len_str };
    const header_type = std.http.Header{ .name = "X-Goog-Upload-Header-Content-Type", .value = mimetype };

    var req = try client.request(.POST, uri, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = &.{ protocol_header, command_header, header_len, header_type },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = metadata.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(metadata);
    try body.end();
    try req.connection.?.flush();

    var head_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&head_buf);

    if (response.head.status != .ok and response.head.status != .created) {
        var err_body = std.Io.Writer.Allocating.init(allocator);
        defer err_body.deinit();
        var transfer_buf: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buf, &decompress, &.{});
        _ = reader.streamRemaining(&err_body.writer) catch {};
        std.log.err("[FileAPI] Start resumable falhou: status={d} body={s}", .{ @intFromEnum(response.head.status), err_body.writer.buffered() });
        return ErroFileApi.HttpError;
    }

    const upload_url = encontrarHeader(response.head, "x-goog-upload-url") orelse {
        std.log.err("[FileAPI] Start resumable nao retornou x-goog-upload-url", .{});
        return ErroFileApi.HttpError;
    };

    // Consome qualquer resto do body antes de encerrar o request.
    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &.{});
    _ = reader.discardRemaining() catch {};

    return allocator.dupe(u8, upload_url);
}

/// Finds a response header by name (case-insensitive). Returns a slice into the existing head buffer.
fn encontrarHeader(head: std.http.Client.Response.Head, name: []const u8) ?[]const u8 {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

/// Extrai "file.name" da resposta JSON de upload (ex: "files/abc123").
pub fn extrairNome(json_raw: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const parsed = std.json.parseFromSlice(
        FileEnvelope,
        allocator,
        json_raw,
        .{ .ignore_unknown_fields = true },
    ) catch return ErroFileApi.JsonMalformado;
    defer parsed.deinit();

    const file = parsed.value.file orelse return ErroFileApi.RespostaVazia;
    const nome = file.name orelse return ErroFileApi.RespostaVazia;
    return allocator.dupe(u8, nome);
}

/// Extrai nome do arquivo a partir de uma URI completa.
/// Ex: "https://.../v1beta/files/abc123" → "abc123"
pub fn nomeDeUri(uri: []const u8) []const u8 {
    const last_slash = std.mem.lastIndexOfScalar(u8, uri, '/') orelse return uri;
    return uri[last_slash + 1 ..];
}

// ---------------------------------------------------------------------------
// Testes (sem HTTP real — apenas funções puras)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "nomeDeUri: extrai nome após último slash" {
    try testing.expectEqualStrings(
        "abc123",
        nomeDeUri("https://generativelanguage.googleapis.com/v1beta/files/abc123"),
    );
    try testing.expectEqualStrings("xyz", nomeDeUri("files/xyz"));
    try testing.expectEqualStrings("solo", nomeDeUri("solo"));
}

test "extrairNome: parse JSON de resposta de upload" {
    const alloc = testing.allocator;
    const json =
        \\{"file":{"name":"files/abc123","displayName":"test","uri":"https://x/abc123","state":"PROCESSING"}}
    ;
    const nome = try extrairNome(json, alloc);
    defer alloc.free(nome);
    try testing.expectEqualStrings("files/abc123", nome);
}

test "extrairUri (via extrairNome JSON) funciona com URI presente" {
    const alloc = testing.allocator;
    const json =
        \\{"file":{"name":"files/vid1","uri":"https://generativelanguage.googleapis.com/v1beta/files/vid1","state":"ACTIVE"}}
    ;
    const uri = try extrairUri(json, alloc);
    defer alloc.free(uri);
    try testing.expect(std.mem.indexOf(u8, uri, "vid1") != null);
}

test "normalizarNomeArquivo: preserva nome canonico e prefixa nome cru" {
    const alloc = testing.allocator;

    const canonico = try normalizarNomeArquivo("files/abc123", alloc);
    defer alloc.free(canonico);
    try testing.expectEqualStrings("files/abc123", canonico);

    const cru = try normalizarNomeArquivo("abc123", alloc);
    defer alloc.free(cru);
    try testing.expectEqualStrings("files/abc123", cru);
}
