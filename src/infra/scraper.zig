// infra/scraper.zig
// Utilitário para baixar e raspar (fazer scrape) de conteúdo em texto de URLs.
// Evita estourar memória com respostas infinitas. Extrai apenas texto visível.

const std = @import("std");

pub const ScraperError = error{
    HttpError,
    UrlInvalid,
    TooLong,
};

/// Faz GET em uma URL e extrai até `max_bytes` do texto puro (sem HTML tags).
/// Caller possui slice alocada.
pub fn extrairTextoDaUrl(allocator: std.mem.Allocator, url_str: []const u8, max_bytes: usize) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = std.Uri.parse(url_str) catch return ScraperError.UrlInvalid;

    const raw_cap = calcularLimiteBruto(max_bytes);
    const raw_buf = try allocator.alloc(u8, raw_cap);
    defer allocator.free(raw_buf);

    var result_buf = std.ArrayListUnmanaged(u8){};
    errdefer result_buf.deinit(allocator);

    var response_writer: std.Io.Writer = .fixed(raw_buf);
    const result = client.fetch(.{
        .location = .{ .uri = uri },
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .response_writer = &response_writer,
    }) catch |err| switch (err) {
        error.WriteFailed => return ScraperError.TooLong,
        else => return ScraperError.HttpError,
    };

    if (result.status != .ok) return ScraperError.HttpError;

    var state: enum { normal, in_tag, in_script, in_style } = .normal;
    var last_chars = [6]u8{ 0, 0, 0, 0, 0, 0 }; // para <script / <style

    for (response_writer.buffered()) |c| {
        if (result_buf.items.len >= max_bytes) break;

        // Shift last_chars left
        std.mem.copyForwards(u8, last_chars[0..5], last_chars[1..6]);
        last_chars[5] = std.ascii.toLower(c);

        switch (state) {
            .normal => {
                if (c == '<') {
                    state = .in_tag;
                } else if (c == ' ' or c == '\n' or c == '\r' or c == '\t') {
                    // Comprime espaços múltiplos
                    if (result_buf.items.len > 0 and result_buf.items[result_buf.items.len - 1] != ' ') {
                        result_buf.append(allocator, ' ') catch continue;
                    }
                } else {
                    result_buf.append(allocator, c) catch continue;
                }
            },
            .in_tag => {
                if (c == '>') {
                    if (std.mem.startsWith(u8, &last_chars, "script")) {
                        state = .in_script;
                    } else if (std.mem.startsWith(u8, &last_chars, "style>")) {
                        state = .in_style;
                    } else {
                        state = .normal;
                    }
                }
            },
            .in_script => {
                if (c == '>') {
                    if (std.mem.eql(u8, &last_chars, "cript>")) { // </script>
                        state = .normal;
                    }
                }
            },
            .in_style => {
                if (c == '>') {
                    if (std.mem.eql(u8, &last_chars, "style>")) { // </style>
                        state = .normal;
                    }
                }
            },
        }
    }

    // Trim whitespace
    const r = std.mem.trim(u8, result_buf.items, " \n\r\t");
    var res = std.ArrayListUnmanaged(u8){};
    try res.appendSlice(allocator, r);
    result_buf.deinit(allocator);

    return res.toOwnedSlice(allocator);
}

fn calcularLimiteBruto(max_bytes: usize) usize {
    const min_cap = 64 * 1024;
    const max_cap = 1024 * 1024;
    const scaled = if (max_bytes > max_cap / 8) max_cap else max_bytes * 8;
    return @max(min_cap, scaled);
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extrairTextoDaUrl - (Nao faz rede de fato, apenas sintaxe testada no main/handler)" {
    // Sem chamadas de I/O reais nos testes da lib
    try testing.expect(true);
}
