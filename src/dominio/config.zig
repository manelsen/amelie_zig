// dominio/config.zig
// Configuração por chat — tipo valor puro, sem I/O.

const std = @import("std");

pub const ModoDescricao = enum {
    normal,
    curto,
    longo,
    legenda,
    cego,

    pub fn fromStr(s: []const u8) ModoDescricao {
        if (std.ascii.eqlIgnoreCase(s, "curto")) return .curto;
        if (std.ascii.eqlIgnoreCase(s, "longo")) return .longo;
        if (std.ascii.eqlIgnoreCase(s, "legenda")) return .legenda;
        if (std.ascii.eqlIgnoreCase(s, "cego")) return .cego;
        return .normal;
    }

    pub fn toStr(self: ModoDescricao) []const u8 {
        return switch (self) {
            .normal  => "normal",
            .curto   => "curto",
            .longo   => "longo",
            .legenda => "legenda",
            .cego    => "cego",
        };
    }
};

pub const Provider = enum {
    gemini,
    openrouter,

    pub fn fromStr(s: []const u8) Provider {
        if (std.ascii.eqlIgnoreCase(s, "openrouter")) return .openrouter;
        return .gemini;
    }

    pub fn toStr(self: Provider) []const u8 {
        return switch (self) {
            .gemini => "gemini",
            .openrouter => "openrouter",
        };
    }
};

/// Configuração per-chat. Todos os campos têm defaults idiomáticos.
/// Campos de mídia refletem os defaults do A-N:
///   imagem=true, audio=false, video=true, documento=true.
pub const Config = struct {
    chat_id:         []const u8    = "",
    temperature:     f64           = 0.9,
    top_k:           u32           = 1,
    top_p:           f64           = 0.95,
    max_tokens:      u32           = 1024,
    media_imagem:    bool          = true,
    media_audio:     bool          = false,
    media_video:     bool          = true,
    media_documento: bool          = true,
    modo_descricao:  ModoDescricao = .normal,
    usar_legenda:    bool          = false,
    provider:        Provider      = .gemini,
    prompt_ativo:    ?[]const u8   = null,
    system_prompt:   []const u8    = "",
};

/// Aplica uma alteração de configuração (campo/valor em string) ao Config.
/// Usado pelo shell ao executar Acao.alterar_config.
pub fn aplicarAlteracao(cfg: *Config, alt: struct { campo: []const u8, valor: []const u8 }) void {
    const Field = enum {
        media_imagem,
        media_audio,
        media_video,
        media_documento,
        modo_descricao,
        usar_legenda,
        provider,
    };

    const FieldMap = std.StaticStringMap(Field).initComptime(.{
        .{ "media_imagem",    .media_imagem },
        .{ "media_audio",     .media_audio },
        .{ "media_video",     .media_video },
        .{ "media_documento", .media_documento },
        .{ "modo_descricao",  .modo_descricao },
        .{ "usar_legenda",    .usar_legenda },
        .{ "provider",        .provider },
    });

    const field = FieldMap.get(alt.campo) orelse return;
    const v = alt.valor;
    const verdadeiro = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on");

    switch (field) {
        .media_imagem    => cfg.media_imagem    = verdadeiro,
        .media_audio     => cfg.media_audio     = verdadeiro,
        .media_video     => cfg.media_video     = verdadeiro,
        .media_documento => cfg.media_documento = verdadeiro,
        .modo_descricao  => cfg.modo_descricao  = ModoDescricao.fromStr(v),
        .usar_legenda    => cfg.usar_legenda    = verdadeiro,
        .provider        => cfg.provider        = Provider.fromStr(v),
    }
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

test "ModoDescricao.fromStr: valores conhecidos" {
    try std.testing.expectEqual(ModoDescricao.curto,  ModoDescricao.fromStr("curto"));
    try std.testing.expectEqual(ModoDescricao.longo,  ModoDescricao.fromStr("longo"));
    try std.testing.expectEqual(ModoDescricao.legenda, ModoDescricao.fromStr("legenda"));
    try std.testing.expectEqual(ModoDescricao.cego,   ModoDescricao.fromStr("cego"));
    try std.testing.expectEqual(ModoDescricao.normal, ModoDescricao.fromStr("outro"));
    try std.testing.expectEqual(ModoDescricao.normal, ModoDescricao.fromStr(""));
}

test "ModoDescricao.fromStr: case insensitive" {
    try std.testing.expectEqual(ModoDescricao.cego, ModoDescricao.fromStr("CEGO"));
    try std.testing.expectEqual(ModoDescricao.longo, ModoDescricao.fromStr("LONGO"));
}

test "ModoDescricao.toStr: roundtrip" {
    inline for (std.meta.fields(ModoDescricao)) |f| {
        const modo: ModoDescricao = @enumFromInt(f.value);
        try std.testing.expectEqual(modo, ModoDescricao.fromStr(modo.toStr()));
    }
}

test "Config: defaults do A-N" {
    const c = Config{};
    try std.testing.expectEqual(true,  c.media_imagem);
    try std.testing.expectEqual(false, c.media_audio);
    try std.testing.expectEqual(true,  c.media_video);
    try std.testing.expectEqual(true,  c.media_documento);
    try std.testing.expectEqual(@as(f64, 0.9), c.temperature);
    try std.testing.expectEqual(@as(?[]const u8, null), c.prompt_ativo);
}
