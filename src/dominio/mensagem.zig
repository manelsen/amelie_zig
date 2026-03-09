// dominio/mensagem.zig
// Mensagem recebida + Conteudo (tagged union).
// Importa Comando para compor Conteudo.

const std    = @import("std");
const cmd    = @import("comando.zig");
pub const Comando = cmd.Comando;

pub const TipoMidia = enum { imagem, audio, video, documento };

pub const Conteudo = union(enum) {
    texto:   []const u8,
    comando: Comando,
    midia:   Midia,

    pub const Midia = struct {
        tipo:     TipoMidia,
        url:      []const u8,
        caption:  ?[]const u8 = null,
        mimetype: ?[]const u8 = null,
        filename: ?[]const u8 = null,
    };
};

/// Mensagem normalizada recebida do WhatsApp.
/// Campos com defaults facilitam a construção em testes.
pub const Mensagem = struct {
    id:           []const u8  = "msg_test",
    chat_id:      []const u8  = "chat_test",
    remetente:    []const u8  = "remetente_test",
    push_name:    ?[]const u8 = null,   // nome de exibição do remetente (Baileys)
    conteudo:     Conteudo    = .{ .texto = "" },
    timestamp:    i64         = 0,
    em_grupo:     bool        = false,
    menciona_bot: bool        = false,
    eh_admin:     bool        = false,  // resolvido pelo shell antes do core
};

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

test "Mensagem: defaults coerentes" {
    const m = Mensagem{};
    try std.testing.expect(!m.em_grupo);
    try std.testing.expect(!m.menciona_bot);
    try std.testing.expect(!m.eh_admin);
    try std.testing.expect(m.conteudo == .texto);
}

test "Conteudo: construção de cada variante" {
    const texto   = Conteudo{ .texto   = "olá" };
    const comando = Conteudo{ .comando = .ajuda };
    const midia   = Conteudo{ .midia   = .{ .tipo = .audio, .url = "http://example.com/a.ogg" } };

    try std.testing.expect(texto   == .texto);
    try std.testing.expect(comando == .comando);
    try std.testing.expect(midia   == .midia);
    try std.testing.expectEqual(TipoMidia.audio, midia.midia.tipo);
}

test "Mensagem: texto com conteudo" {
    const m = Mensagem{ .conteudo = .{ .texto = "como vai?" } };
    try std.testing.expectEqualStrings("como vai?", m.conteudo.texto);
}

test "Mensagem: midia com caption opcional" {
    const m = Mensagem{
        .conteudo = .{ .midia = .{
            .tipo    = .imagem,
            .url     = "http://example.com/foto.jpg",
            .caption = "Uma foto bonita",
        }},
    };
    try std.testing.expectEqual(TipoMidia.imagem, m.conteudo.midia.tipo);
    try std.testing.expectEqualStrings("Uma foto bonita", m.conteudo.midia.caption.?);
}
