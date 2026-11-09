// infra/json_util.zig
// Shared JSON-building helpers used by both GeminiAdapter and OpenRouterAdapter.

const std = @import("std");

/// Writes a JSON-encoded string with surrounding quotes to `w`,
/// escaping `"`, `\`, `\n`, `\r`, and `\t`.
pub fn escreverStringJson(w: anytype, s: []const u8) !void {
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

/// Trims whitespace and strips any leading `amélie:` / `amelie:` / `Amélie:` / `Amelie:` prefix from the model output.
pub fn limparResposta(texto: []const u8) []const u8 {
    var t = std.mem.trim(u8, texto, " \t\n\r");
    inline for (.{ "amélie:", "amelie:", "Amélie:", "Amelie:" }) |prefix| {
        if (std.mem.startsWith(u8, t, prefix)) {
            t = std.mem.trim(u8, t[prefix.len..], " ");
            break;
        }
    }
    return t;
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

test "escreverStringJson: escapa caracteres especiais" {
    const alloc = testing.allocator;
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);

    try escreverStringJson(buf.writer(alloc), "linha1\nlinha2\t\"aspas\"\\barra");
    const result = buf.items;

    try testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\\t") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\\\\") != null);
}

test "escreverStringJson: string vazia → apenas aspas" {
    const alloc = testing.allocator;
    var buf = std.ArrayListUnmanaged(u8){};
    defer buf.deinit(alloc);
    try escreverStringJson(buf.writer(alloc), "");
    try testing.expectEqualStrings("\"\"", buf.items);
}

test "limparResposta: remove prefixos amélie:/amelie:/Amélie:/Amelie:" {
    try testing.expectEqualStrings("Olá!", limparResposta("amélie: Olá!"));
    try testing.expectEqualStrings("Olá!", limparResposta("amelie: Olá!"));
    try testing.expectEqualStrings("Olá!", limparResposta("Amélie: Olá!"));
    try testing.expectEqualStrings("Olá!", limparResposta("Amelie: Olá!"));
    try testing.expectEqualStrings("Texto normal.", limparResposta("Texto normal."));
}

test "limparResposta: remove espaços e newlines das bordas" {
    try testing.expectEqualStrings("ok", limparResposta("  ok  "));
    try testing.expectEqualStrings("ok", limparResposta("\n ok \n"));
}

test "limparResposta: string vazia → vazia" {
    try testing.expectEqualStrings("", limparResposta(""));
}

test "limparResposta: só espaços → vazia" {
    try testing.expectEqualStrings("", limparResposta("   "));
}
