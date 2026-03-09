// dominio/acao.zig
// Acao: o que o core prescreve; o shell executa.
// Cada variante encapsula todos os dados que o shell precisa.

const mensagem = @import("mensagem.zig");
pub const TipoMidia = mensagem.TipoMidia;

pub const Acao = union(enum) {
    /// Nada a fazer (duplicata, grupo não mencionado, toggle off sem mudança).
    ignorar,

    /// Texto literal estático — sem I/O, sem DB.
    /// Ex: resposta do .ajuda, feedback de toggle.
    responder: []const u8,

    /// Chamar IA e enviar resposta ao usuário.
    invocar_ia: InvocarIA,

    /// Enfileirar processamento de mídia (thread pool).
    enfileirar_midia: mensagem.Conteudo.Midia,

    /// Persistir alteração de campo único na config.
    /// Shell escreve no DB e envia feedback ao usuário.
    alterar_config: AlterarConfig,

    /// Resetar config completa para defaults.
    resetar_config,

    /// Ativar modo cego (multi-campo: modo_descricao + toggles de mídia).
    ativar_modo_cego,

    /// Persistir prompt customizado.
    salvar_prompt: SalvarPrompt,

    /// Ativar prompt pelo nome (shell verifica existência antes).
    ativar_prompt: []const u8,

    /// Deletar prompt pelo nome.
    deletar_prompt: []const u8,

    /// Desativar prompt ativo (limpa config.prompt_ativo).
    limpar_prompt_ativo,

    /// Reagir a uma mensagem específica.
    reagir: Reacao,

    // Consultas: shell busca dados no DB e responde.
    listar_prompts,
    listar_usuarios,
    obter_status,
    limpar_filas,

    // -----------------------------------------------------------------------

    pub const InvocarIA = struct {
        prompt:            []const u8,
        system_prompt:     ?[]const u8 = null,
        incluir_historico: bool        = true,
    };

    pub const Reacao = struct {
        emoji:  []const u8,
        msg_id: []const u8,
    };

    pub const AlterarConfig = struct {
        campo: []const u8,
        valor: []const u8,
        // Sem feedback aqui — shell monta a mensagem de confirmação.
    };

    pub const SalvarPrompt = struct {
        nome:     []const u8,
        conteudo: []const u8,
    };
};

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const std = @import("std");

test "Acao: tagged union discrimina corretamente" {
    const a1: Acao = .ignorar;
    const a2: Acao = .{ .responder = "olá" };
    const a3: Acao = .{ .invocar_ia = .{ .prompt = "oi" } };
    const a4: Acao = .{ .enfileirar_midia = .{ .tipo = .audio, .url = "url" } };
    const a5: Acao = .{ .alterar_config = .{ .campo = "media_audio", .valor = "true" } };

    try std.testing.expect(a1 == .ignorar);
    try std.testing.expect(a2 == .responder);
    try std.testing.expect(a3 == .invocar_ia);
    try std.testing.expect(a4 == .enfileirar_midia);
    try std.testing.expect(a5 == .alterar_config);
}

test "Acao.InvocarIA: defaults" {
    const a = Acao.InvocarIA{ .prompt = "teste" };
    try std.testing.expectEqual(true, a.incluir_historico);
    try std.testing.expectEqual(@as(?[]const u8, null), a.system_prompt);
}

test "Acao.enfileirar_midia: todos os tipos de mídia" {
    inline for (std.meta.fields(TipoMidia)) |f| {
        const tipo: TipoMidia = @enumFromInt(f.value);
        const a = Acao{ .enfileirar_midia = .{ .tipo = tipo, .url = "url" } };
        try std.testing.expectEqual(tipo, a.enfileirar_midia.tipo);
    }
}
