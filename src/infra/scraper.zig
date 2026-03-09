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

    var req = client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } }
    }) catch return ScraperError.HttpError;
    defer req.deinit();

    req.sendBodiless() catch return ScraperError.HttpError;

    var head_buf: [8192]u8 = undefined;
    var head = req.receiveHead(&head_buf) catch return ScraperError.HttpError;

    if (head.head.status != .ok) return ScraperError.HttpError;

    var result_buf = std.ArrayListUnmanaged(u8){};
    errdefer result_buf.deinit(allocator);

    var reader = head.reader(&.{});
    var transfer_buf: [8192]u8 = undefined;

    var state: enum { normal, in_tag, in_script, in_style } = .normal;
    var last_chars = [6]u8{ 0, 0, 0, 0, 0, 0 }; // para <script / <style

    while (true) {
        const n = reader.readSliceShort(&transfer_buf) catch return ScraperError.HttpError;
        if (n == 0) break;

        for (transfer_buf[0..n]) |c| {
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
        if (result_buf.items.len >= max_bytes) break;
    }

    // Trim whitespace
    const r = std.mem.trim(u8, result_buf.items, " \n\r\t");
    var res = std.ArrayListUnmanaged(u8){};
    try res.appendSlice(allocator, r);
    result_buf.deinit(allocator);

    return res.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extrairTextoDaUrl - (Nao faz rede de fato, apenas sintaxe testada no main/handler)" {
    // Sem chamadas de I/O reais nos testes da lib
    try testing.expect(true);
}
