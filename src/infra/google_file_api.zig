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

pub const URL_UPLOAD = "https://generativelanguage.googleapis.com/upload/v1beta/files";
pub const URL_FILES  = "https://generativelanguage.googleapis.com/v1beta/files/";

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

const FileResponse = struct {
    file: ?FileInfo = null,
};

const FileInfo = struct {
    name:  ?[]const u8 = null,
    uri:   ?[]const u8 = null,
    state: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// uploadArquivo — multipart/related upload
// Retorna fileUri alocado no allocator fornecido. Caller libera.
// ---------------------------------------------------------------------------

pub fn uploadArquivo(
    api_key:  []const u8,
    dados:    []const u8,  // bytes crus (não base64)
    mimetype: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    // Monta body multipart
    var body = std.ArrayListUnmanaged(u8){};
    defer body.deinit(allocator);
    const w = body.writer(allocator);

    // Parte 1: metadados JSON
    try w.print("--{s}\r\n", .{BOUNDARY});
    try w.writeAll("Content-Type: application/json; charset=utf-8\r\n\r\n");
    try w.writeAll("{\"file\":{\"display_name\":\"amelie_upload\"}}\r\n");

    // Parte 2: dados binários
    try w.print("--{s}\r\n", .{BOUNDARY});
    try w.print("Content-Type: {s}\r\n\r\n", .{mimetype});
    try w.writeAll(dados);
    try w.print("\r\n--{s}--\r\n", .{BOUNDARY});

    // Monta header Content-Type
    const ct = try std.fmt.allocPrint(
        allocator,
        "multipart/related; boundary={s}",
        .{BOUNDARY},
    );
    defer allocator.free(ct);

    // Monta URL com api_key
    const url_str = try std.fmt.allocPrint(
        allocator,
        "{s}?key={s}",
        .{ URL_UPLOAD, api_key },
    );
    defer allocator.free(url_str);

    const uri = std.Uri.parse(url_str) catch return ErroFileApi.UrlInvalida;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const ct_header = std.http.Header{ .name = "Content-Type", .value = ct };

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{ct_header},
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.items.len };
    var stream = try req.sendBodyUnflushed(&.{});
    try stream.writer.writeAll(body.items);
    try stream.end();
    try req.connection.?.flush();

    var head_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&head_buf);

    if (response.head.status != .ok and response.head.status != .created) {
        return ErroFileApi.HttpError;
    }

    var res_buf = std.ArrayListUnmanaged(u8){};
    defer res_buf.deinit(allocator);
    var tbuf: [8192]u8 = undefined;
    var reader = response.reader(&.{});
    while (true) {
        const n = try reader.readSliceShort(&tbuf);
        if (n == 0) break;
        try res_buf.appendSlice(allocator, tbuf[0..n]);
    }

    return extrairUri(res_buf.items, allocator);
}

// ---------------------------------------------------------------------------
// aguardarAtivo — poll até state == "ACTIVE" (max 60 tentativas × 2s = 2min)
// ---------------------------------------------------------------------------

pub fn aguardarAtivo(
    api_key:   []const u8,
    file_name: []const u8,  // ex: "files/abc123"
    allocator: std.mem.Allocator,
) !void {
    const url_str = try std.fmt.allocPrint(
        allocator,
        "{s}{s}?key={s}",
        .{ URL_FILES, file_name, api_key },
    );
    defer allocator.free(url_str);

    var tentativas: u8 = 0;
    while (tentativas < 60) : (tentativas += 1) {
        std.time.sleep(2 * std.time.ns_per_s);

        const state = try verificarEstado(url_str, allocator);
        defer allocator.free(state);

        if (std.mem.eql(u8, state, "ACTIVE")) return;
        if (std.mem.eql(u8, state, "FAILED")) return ErroFileApi.HttpError;

        std.log.debug("[FileAPI] Arquivo {s}: estado={s}, tentativa {d}", .{ file_name, state, tentativas });
    }
    return ErroFileApi.TimeoutAtivo;
}

fn verificarEstado(url_str: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const uri = std.Uri.parse(url_str) catch return ErroFileApi.UrlInvalida;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var req = try client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();

    try req.sendBodiless();

    var head_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&head_buf);

    if (response.head.status != .ok) return ErroFileApi.HttpError;

    var res_buf = std.ArrayListUnmanaged(u8){};
    defer res_buf.deinit(allocator);
    var tbuf: [8192]u8 = undefined;
    var reader = response.reader(&.{});
    while (true) {
        const n = try reader.readSliceShort(&tbuf);
        if (n == 0) break;
        try res_buf.appendSlice(allocator, tbuf[0..n]);
    }

    // Extrai "state" do JSON
    const parsed = std.json.parseFromSlice(
        FileResponse, allocator, res_buf.items, .{ .ignore_unknown_fields = true },
    ) catch return ErroFileApi.JsonMalformado;
    defer parsed.deinit();

    const state = parsed.value.file.?.state orelse return allocator.dupe(u8, "PROCESSING");
    return allocator.dupe(u8, state);
}

// ---------------------------------------------------------------------------
// deletarArquivo — cleanup após uso. Ignora erros (best-effort).
// ---------------------------------------------------------------------------

pub fn deletarArquivo(
    api_key:   []const u8,
    file_name: []const u8,
    allocator: std.mem.Allocator,
) void {
    const url_str = std.fmt.allocPrint(
        allocator,
        "{s}{s}?key={s}",
        .{ URL_FILES, file_name, api_key },
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
    const parsed = std.json.parseFromSlice(
        FileResponse, allocator, json_raw, .{ .ignore_unknown_fields = true },
    ) catch return ErroFileApi.JsonMalformado;
    defer parsed.deinit();

    const file = parsed.value.file orelse return ErroFileApi.RespostaVazia;
    const uri  = file.uri   orelse return ErroFileApi.RespostaVazia;
    return allocator.dupe(u8, uri);
}

/// Extrai "file.name" da resposta JSON de upload (ex: "files/abc123").
pub fn extrairNome(json_raw: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const parsed = std.json.parseFromSlice(
        FileResponse, allocator, json_raw, .{ .ignore_unknown_fields = true },
    ) catch return ErroFileApi.JsonMalformado;
    defer parsed.deinit();

    const file = parsed.value.file orelse return ErroFileApi.RespostaVazia;
    const nome = file.name orelse return ErroFileApi.RespostaVazia;
    // Remove prefixo "files/" se presente para usar como path component
    const s = if (std.mem.startsWith(u8, nome, "files/")) nome["files/".len..] else nome;
    return allocator.dupe(u8, s);
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
    try testing.expectEqualStrings("abc123", nome);
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
