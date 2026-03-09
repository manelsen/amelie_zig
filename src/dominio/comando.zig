// dominio/comando.zig
// Comando: tagged union com payloads explícitos.
// parsear() é pura — sem alocador, sem I/O.
// Retorna slices apontando para o input original.

const std = @import("std");

pub const Entrada = struct {
    nome: []const u8,
    valor: []const u8,
};

pub const Comando = union(enum) {
    // Comandos simples
    ajuda,
    ping,
    info,
    reset,
    status,
    audio,
    imagem,
    video,
    doc,
    curto,
    longo,
    legenda,
    cego,
    filas_limpar,

    // Comandos com subcomandos
    prompt: SubcmdPrompt,
    config: SubcmdConfig,

    // Texto que começa com '.' mas não é reconhecido
    desconhecido: []const u8,

    pub const SubcmdPrompt = union(enum) {
        listar,
        limpar,
        criar: Entrada, // .prompt set nome conteudo
        usar: []const u8, // .prompt use nome
        obter: []const u8, // .prompt get nome
        deletar: []const u8, // .prompt delete nome
        gerar: []const u8, // .prompt "texto livre" → Gemini gera
    };

    pub const SubcmdConfig = union(enum) {
        obter: []const u8, // .config get campo
        definir: Entrada, // .config set campo valor
    };

    /// Parse puro: sem alocador, sem I/O.
    /// Retorna slices no input original — o caller garante lifetime.
    pub fn parsear(texto: []const u8) Comando {
        const t = std.mem.trim(u8, texto, " \t\n\r");
        if (t.len == 0) return .{ .desconhecido = t };

        const first_char = t[0];
        if (first_char != '.' and first_char != '/' and first_char != '!') {
            return .{ .desconhecido = t };
        }

        const corpo = t[1..]; // remove o prefixo (., /, !)
        const espaco = std.mem.indexOfScalar(u8, corpo, ' ');
        const cmd = if (espaco) |i| corpo[0..i] else corpo;
        const args = if (espaco) |i| std.mem.trimLeft(u8, corpo[i + 1 ..], " ") else "";

        if (eq(cmd, "ajuda") or eq(cmd, "help")) return .ajuda;
        if (eq(cmd, "ping")) return .ping;
        if (eq(cmd, "info")) return .info;
        if (eq(cmd, "reset")) return .reset;
        if (eq(cmd, "status")) return .status;
        if (eq(cmd, "audio")) return .audio;
        if (eq(cmd, "imagem")) return .imagem;
        if (eq(cmd, "video")) return .video;
        if (eq(cmd, "doc")) return .doc;
        if (eq(cmd, "curto")) return .curto;
        if (eq(cmd, "longo")) return .longo;
        if (eq(cmd, "legenda")) return .legenda;
        if (eq(cmd, "cego")) return .cego;
        if (eq(cmd, "filas")) return .filas_limpar;
        if (eq(cmd, "prompt")) return .{ .prompt = subPrompt(args) };
        if (eq(cmd, "config")) return .{ .config = subConfig(args) };

        return .{ .desconhecido = t };
    }

    // -----------------------------------------------------------------------
    // Helpers privados
    // -----------------------------------------------------------------------

    fn eq(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    fn proxPalavra(s: []const u8) struct { palavra: []const u8, resto: []const u8 } {
        const i = std.mem.indexOfScalar(u8, s, ' ') orelse return .{ .palavra = s, .resto = "" };
        return .{
            .palavra = s[0..i],
            .resto = std.mem.trimLeft(u8, s[i + 1 ..], " "),
        };
    }

    fn subPrompt(args: []const u8) SubcmdPrompt {
        if (args.len == 0) return .{ .gerar = args };

        const p = proxPalavra(args);

        if (eq(p.palavra, "list") or eq(p.palavra, "listar")) return .listar;
        if (eq(p.palavra, "clear") or eq(p.palavra, "limpar")) return .limpar;

        if (eq(p.palavra, "set") or eq(p.palavra, "criar")) {
            const n = proxPalavra(p.resto);
            return .{ .criar = .{ .nome = n.palavra, .valor = n.resto } };
        }
        if (eq(p.palavra, "use") or eq(p.palavra, "usar")) return .{ .usar = p.resto };
        if (eq(p.palavra, "get") or eq(p.palavra, "obter")) return .{ .obter = p.resto };
        if (eq(p.palavra, "delete") or eq(p.palavra, "del") or eq(p.palavra, "deletar")) return .{ .deletar = p.resto };

        // Subcomando não reconhecido → trata args completo como texto de geração
        return .{ .gerar = args };
    }

    fn subConfig(args: []const u8) SubcmdConfig {
        if (args.len == 0) return .{ .obter = "" };

        const p = proxPalavra(args);

        if (eq(p.palavra, "get") or eq(p.palavra, "obter")) return .{ .obter = p.resto };
        if (eq(p.palavra, "set") or eq(p.palavra, "definir")) {
            const n = proxPalavra(p.resto);
            return .{ .definir = .{ .nome = n.palavra, .valor = n.resto } };
        }

        return .{ .obter = args };
    }
};

// ---------------------------------------------------------------------------
// Testes — RED esperado para casos incomuns até parsear() estar completo
// ---------------------------------------------------------------------------

test "parsear: comandos simples" {
    try std.testing.expect(Comando.parsear(".ajuda") == .ajuda);
    try std.testing.expect(Comando.parsear(".help") == .ajuda);
    try std.testing.expect(Comando.parsear("/ping") == .ping);
    try std.testing.expect(Comando.parsear("!info") == .info);
    try std.testing.expect(Comando.parsear(".reset") == .reset);
    try std.testing.expect(Comando.parsear(".status") == .status);
    try std.testing.expect(Comando.parsear(".audio") == .audio);
    try std.testing.expect(Comando.parsear(".imagem") == .imagem);
    try std.testing.expect(Comando.parsear(".video") == .video);
    try std.testing.expect(Comando.parsear(".doc") == .doc);
    try std.testing.expect(Comando.parsear(".curto") == .curto);
    try std.testing.expect(Comando.parsear(".longo") == .longo);
    try std.testing.expect(Comando.parsear(".legenda") == .legenda);
    try std.testing.expect(Comando.parsear(".cego") == .cego);
    try std.testing.expect(Comando.parsear(".filas") == .filas_limpar);
}

test "parsear: case insensitive" {
    try std.testing.expect(Comando.parsear(".AJUDA") == .ajuda);
    try std.testing.expect(Comando.parsear(".Audio") == .audio);
    try std.testing.expect(Comando.parsear(".RESET") == .reset);
}

test "parsear: texto sem ponto → desconhecido" {
    const r = Comando.parsear("olá tudo bem");
    try std.testing.expect(r == .desconhecido);
}

test "parsear: string vazia → desconhecido" {
    const r = Comando.parsear("");
    try std.testing.expect(r == .desconhecido);
}

test "parsear: ponto desconhecido → desconhecido" {
    const r = Comando.parsear(".xyzinexistente");
    try std.testing.expect(r == .desconhecido);
}

test "parsear: espaços em volta → ignora" {
    try std.testing.expect(Comando.parsear("  .ajuda  ") == .ajuda);
}

test "parsear: .prompt list" {
    const r = Comando.parsear(".prompt list");
    try std.testing.expect(r == .prompt);
    try std.testing.expect(r.prompt == .listar);
}

test "parsear: .prompt listar (português)" {
    const r = Comando.parsear(".prompt listar");
    try std.testing.expect(r == .prompt);
    try std.testing.expect(r.prompt == .listar);
}

test "parsear: .prompt clear" {
    const r = Comando.parsear(".prompt clear");
    try std.testing.expect(r == .prompt);
    try std.testing.expect(r.prompt == .limpar);
}

test "parsear: .prompt set nome conteudo" {
    const r = Comando.parsear(".prompt set meu_prompt Seja conciso e direto.");
    try std.testing.expect(r == .prompt);
    try std.testing.expect(r.prompt == .criar);
    try std.testing.expectEqualStrings("meu_prompt", r.prompt.criar.nome);
    try std.testing.expectEqualStrings("Seja conciso e direto.", r.prompt.criar.valor);
}

test "parsear: .prompt set nome vazio quando sem valor" {
    const r = Comando.parsear(".prompt set apenas_nome");
    try std.testing.expect(r == .prompt);
    try std.testing.expect(r.prompt == .criar);
    try std.testing.expectEqualStrings("apenas_nome", r.prompt.criar.nome);
    try std.testing.expectEqualStrings("", r.prompt.criar.valor);
}

test "parsear: .prompt use nome" {
    const r = Comando.parsear(".prompt use chef_de_cozinha");
    try std.testing.expect(r == .prompt);
    try std.testing.expect(r.prompt == .usar);
    try std.testing.expectEqualStrings("chef_de_cozinha", r.prompt.usar);
}

test "parsear: .prompt get nome" {
    const r = Comando.parsear(".prompt get meu_prompt");
    try std.testing.expect(r == .prompt);
    try std.testing.expect(r.prompt == .obter);
    try std.testing.expectEqualStrings("meu_prompt", r.prompt.obter);
}

test "parsear: .prompt delete nome" {
    const r = Comando.parsear(".prompt delete meu_prompt");
    try std.testing.expect(r == .prompt);
    try std.testing.expect(r.prompt == .deletar);
    try std.testing.expectEqualStrings("meu_prompt", r.prompt.deletar);
}

test "parsear: .prompt texto_livre → gerar" {
    const r = Comando.parsear(".prompt Me ajude a criar um prompt para revisar textos.");
    try std.testing.expect(r == .prompt);
    try std.testing.expect(r.prompt == .gerar);
    try std.testing.expectEqualStrings(
        "Me ajude a criar um prompt para revisar textos.",
        r.prompt.gerar,
    );
}

test "parsear: .prompt sozinho → gerar com args vazio" {
    const r = Comando.parsear(".prompt");
    try std.testing.expect(r == .prompt);
    try std.testing.expect(r.prompt == .gerar);
}

test "parsear: .config get temperature" {
    const r = Comando.parsear(".config get temperature");
    try std.testing.expect(r == .config);
    try std.testing.expect(r.config == .obter);
    try std.testing.expectEqualStrings("temperature", r.config.obter);
}

test "parsear: .config set temperature 0.7" {
    const r = Comando.parsear(".config set temperature 0.7");
    try std.testing.expect(r == .config);
    try std.testing.expect(r.config == .definir);
    try std.testing.expectEqualStrings("temperature", r.config.definir.nome);
    try std.testing.expectEqualStrings("0.7", r.config.definir.valor);
}

test "parsear: .config set mediaAudio false" {
    const r = Comando.parsear(".config set mediaAudio false");
    try std.testing.expect(r == .config);
    try std.testing.expect(r.config == .definir);
    try std.testing.expectEqualStrings("mediaAudio", r.config.definir.nome);
    try std.testing.expectEqualStrings("false", r.config.definir.valor);
}

test "parsear: .config sozinho → obter string vazia" {
    const r = Comando.parsear(".config");
    try std.testing.expect(r == .config);
    try std.testing.expect(r.config == .obter);
}
