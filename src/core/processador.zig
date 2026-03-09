// core/processador.zig
// Núcleo puro: sem I/O, sem alocador, sem efeitos colaterais.
// Contrato: (Mensagem, Config) → Acao
//
// TDD: testes estão na seção abaixo. Implementação stub — todos falham.
// Execute: zig build test

const std = @import("std");

const msg_mod = @import("../dominio/mensagem.zig");
const acao_mod = @import("../dominio/acao.zig");
const cfg_mod = @import("../dominio/config.zig");
const cmd_mod = @import("../dominio/comando.zig");

pub const Mensagem = msg_mod.Mensagem;
pub const Conteudo = msg_mod.Conteudo;
pub const TipoMidia = msg_mod.TipoMidia;
pub const Acao = acao_mod.Acao;
pub const Config = cfg_mod.Config;
pub const Comando = cmd_mod.Comando;

// ---------------------------------------------------------------------------
// Texto de ajuda — constante de compilação, sem alocador.
// ---------------------------------------------------------------------------
pub const TEXTO_AJUDA =
    "*Comandos disponíveis:*\n\n" ++
    "*.ajuda* — esta mensagem\n" ++
    "*/ping* — verifica se estou online\n" ++
    "*/info* — dados da versão atual\n" ++
    "*.audio* — liga/desliga transcrição de áudio\n" ++
    "*.video* — liga/desliga análise de vídeo\n" ++
    "*.imagem* — liga/desliga descrição de imagem\n" ++
    "*.doc* — liga/desliga análise de documento\n" ++
    "*.curto* — modo descrição curta\n" ++
    "*.longo* — modo descrição longa\n" ++
    "*.legenda* — modo legenda (surdos)\n" ++
    "*.cego* — modo acessibilidade visual\n" ++
    "*.prompt set nome conteudo* — salva prompt\n" ++
    "*.prompt use nome* — ativa prompt salvo\n" ++
    "*.prompt get nome* — exibe prompt salvo\n" ++
    "*.prompt list* — lista prompts salvos\n" ++
    "*.prompt delete nome* — remove prompt\n" ++
    "*.prompt clear* — desativa prompt ativo\n" ++
    "*.config set campo valor* — altera configuração\n" ++
    "*.config get campo* — consulta configuração\n" ++
    "*.status* — status do bot\n" ++
    "*.reset* — restaura configurações padrão\n";

// ---------------------------------------------------------------------------
// Função principal — STUB (TDD red)
// ---------------------------------------------------------------------------

/// Processa uma mensagem e retorna a ação a executar.
/// Pura: sem I/O, sem alocador, sem efeitos.
pub fn processar(msg: Mensagem, config: Config) Acao {
    // Filtros globais
    if (std.mem.eql(u8, msg.chat_id, "status@broadcast")) return .ignorar;
    if (msg.em_grupo and !msg.menciona_bot) return .ignorar;

    return switch (msg.conteudo) {
        .texto => |t| .{ .invocar_ia = .{ .prompt = t } },
        .midia => |m| processarMidia(m, config),
        .comando => |c| processarComando(c, config),
    };
}

fn processarMidia(midia: Conteudo.Midia, config: Config) Acao {
    const ativo = switch (midia.tipo) {
        .imagem => config.media_imagem,
        .audio => config.media_audio,
        .video => config.media_video,
        .documento => config.media_documento,
    };
    return if (ativo) .{ .enfileirar_midia = midia } else .ignorar;
}

fn processarComando(cmd: Comando, config: Config) Acao {
    return switch (cmd) {
        .ajuda => .{ .responder = TEXTO_AJUDA },
        .ping => .{ .responder = "🏓 Pong! Amélie Zig está operando com sucesso." },
        .info => .{ .responder = "💻 Amélie construída em Zig 0.15\n\nPerformance ultra-alta (1.1MB de binário, ~0.3MB RAM).\nMotor resiliente ativado." },
        .reset => .resetar_config,
        .status => .obter_status,
        .filas_limpar => .limpar_filas,
        .cego => .ativar_modo_cego,

        // Modos de descrição
        .curto => .{ .alterar_config = .{ .campo = "modo_descricao", .valor = "curto" } },
        .longo => .{ .alterar_config = .{ .campo = "modo_descricao", .valor = "longo" } },
        .legenda => .{ .alterar_config = .{ .campo = "modo_descricao", .valor = "legenda" } },

        // Toggles de mídia — valor depende do estado atual em Config
        .audio => .{ .alterar_config = .{
            .campo = "media_audio",
            .valor = if (config.media_audio) "false" else "true",
        } },
        .imagem => .{ .alterar_config = .{
            .campo = "media_imagem",
            .valor = if (config.media_imagem) "false" else "true",
        } },
        .video => .{ .alterar_config = .{
            .campo = "media_video",
            .valor = if (config.media_video) "false" else "true",
        } },
        .doc => .{ .alterar_config = .{
            .campo = "media_documento",
            .valor = if (config.media_documento) "false" else "true",
        } },

        // Prompt
        .prompt => |sub| processarSubPrompt(sub),

        // Config
        .config => |sub| switch (sub) {
            .definir => |e| .{ .alterar_config = .{ .campo = e.nome, .valor = e.valor } },
            .obter => .{ .responder = "" }, // shell substitui pelo valor real
        },

        .desconhecido => .ignorar,
    };
}

fn processarSubPrompt(sub: Comando.SubcmdPrompt) Acao {
    return switch (sub) {
        .listar => .listar_prompts,
        .limpar => .limpar_prompt_ativo,
        .criar => |e| .{ .salvar_prompt = .{ .nome = e.nome, .conteudo = e.valor } },
        .usar => |n| .{ .ativar_prompt = n },
        .obter => |n| .{ .ativar_prompt = n }, // shell exibe, não ativa
        .deletar => |n| .{ .deletar_prompt = n },
        .gerar => |t| .{ .invocar_ia = .{
            .prompt = t,
            .incluir_historico = false,
        } },
    };
}

// ---------------------------------------------------------------------------
// Testes — TDD RED: todos devem falhar com o stub acima.
// ---------------------------------------------------------------------------

test "texto: mensagem simples → invocar_ia" {
    const m = Mensagem{ .conteudo = .{ .texto = "olá, tudo bem?" } };
    const a = processar(m, .{});
    try std.testing.expect(a == .invocar_ia);
    try std.testing.expectEqualStrings("olá, tudo bem?", a.invocar_ia.prompt);
}

test "texto: inclui histórico por padrão" {
    const m = Mensagem{ .conteudo = .{ .texto = "me conte uma piada" } };
    const a = processar(m, .{});
    try std.testing.expect(a == .invocar_ia);
    try std.testing.expectEqual(true, a.invocar_ia.incluir_historico);
}

test "filtro: grupo sem mencionar bot → ignorar" {
    const m = Mensagem{
        .conteudo = .{ .texto = "olá grupo" },
        .em_grupo = true,
        .menciona_bot = false,
    };
    try std.testing.expect(processar(m, .{}) == .ignorar);
}

test "filtro: grupo mencionando bot → invocar_ia" {
    const m = Mensagem{
        .conteudo = .{ .texto = "olá @amelie" },
        .em_grupo = true,
        .menciona_bot = true,
    };
    try std.testing.expect(processar(m, .{}) == .invocar_ia);
}

test "filtro: status@broadcast → ignorar" {
    const m = Mensagem{
        .chat_id = "status@broadcast",
        .conteudo = .{ .texto = "status" },
    };
    try std.testing.expect(processar(m, .{}) == .ignorar);
}

// --- Mídia ---

test "midia: audio com toggle desligado (default) → ignorar" {
    const m = Mensagem{
        .conteudo = .{ .midia = .{ .tipo = .audio, .url = "http://x.com/a.ogg" } },
    };
    const c = Config{ .media_audio = false }; // default
    try std.testing.expect(processar(m, c) == .ignorar);
}

test "midia: audio com toggle ligado → enfileirar_midia .audio" {
    const m = Mensagem{
        .conteudo = .{ .midia = .{ .tipo = .audio, .url = "http://x.com/a.ogg" } },
    };
    const c = Config{ .media_audio = true };
    const a = processar(m, c);
    try std.testing.expect(a == .enfileirar_midia);
    try std.testing.expectEqual(TipoMidia.audio, a.enfileirar_midia.tipo);
}

test "midia: imagem com toggle ligado (default) → enfileirar_midia .imagem" {
    const m = Mensagem{
        .conteudo = .{ .midia = .{ .tipo = .imagem, .url = "http://x.com/foto.jpg" } },
    };
    try std.testing.expect(processar(m, .{}) == .enfileirar_midia);
    try std.testing.expectEqual(TipoMidia.imagem, processar(m, .{}).enfileirar_midia.tipo);
}

test "midia: imagem com toggle desligado → ignorar" {
    const m = Mensagem{
        .conteudo = .{ .midia = .{ .tipo = .imagem, .url = "http://x.com/foto.jpg" } },
    };
    const c = Config{ .media_imagem = false };
    try std.testing.expect(processar(m, c) == .ignorar);
}

test "midia: video com toggle ligado (default) → enfileirar_midia .video" {
    const m = Mensagem{
        .conteudo = .{ .midia = .{ .tipo = .video, .url = "http://x.com/v.mp4" } },
    };
    try std.testing.expectEqual(TipoMidia.video, processar(m, .{}).enfileirar_midia.tipo);
}

test "midia: documento com toggle desligado → ignorar" {
    const m = Mensagem{
        .conteudo = .{ .midia = .{ .tipo = .documento, .url = "http://x.com/f.pdf" } },
    };
    const c = Config{ .media_documento = false };
    try std.testing.expect(processar(m, c) == .ignorar);
}

// --- Comandos simples ---

test "comando .ajuda → responder com texto de ajuda" {
    const m = Mensagem{ .conteudo = .{ .comando = .ajuda } };
    const a = processar(m, .{});
    try std.testing.expect(a == .responder);
    // Verifica que começa com o cabeçalho esperado
    try std.testing.expect(std.mem.startsWith(u8, a.responder, "*Comandos"));
}

test "comando .ping → responder com pong" {
    const m = Mensagem{ .conteudo = .{ .comando = .ping } };
    const a = processar(m, .{});
    try std.testing.expect(a == .responder);
    try std.testing.expect(std.mem.startsWith(u8, a.responder, "🏓 Pong!"));
}

test "comando .info → responder com info info" {
    const m = Mensagem{ .conteudo = .{ .comando = .info } };
    const a = processar(m, .{});
    try std.testing.expect(a == .responder);
    try std.testing.expect(std.mem.startsWith(u8, a.responder, "💻 Amélie"));
}

test "comando .reset → resetar_config" {
    const m = Mensagem{ .conteudo = .{ .comando = .reset } };
    try std.testing.expect(processar(m, .{}) == .resetar_config);
}

test "comando .status → obter_status" {
    const m = Mensagem{ .conteudo = .{ .comando = .status } };
    try std.testing.expect(processar(m, .{}) == .obter_status);
}

test "comando .filas_limpar → limpar_filas" {
    const m = Mensagem{ .conteudo = .{ .comando = .filas_limpar } };
    try std.testing.expect(processar(m, .{}) == .limpar_filas);
}

// --- Toggles de mídia ---

test "comando .audio: toggle off→on → alterar_config media_audio=true" {
    const m = Mensagem{ .conteudo = .{ .comando = .audio } };
    const c = Config{ .media_audio = false };
    const a = processar(m, c);
    try std.testing.expect(a == .alterar_config);
    try std.testing.expectEqualStrings("media_audio", a.alterar_config.campo);
    try std.testing.expectEqualStrings("true", a.alterar_config.valor);
}

test "comando .audio: toggle on→off → alterar_config media_audio=false" {
    const m = Mensagem{ .conteudo = .{ .comando = .audio } };
    const c = Config{ .media_audio = true };
    const a = processar(m, c);
    try std.testing.expect(a == .alterar_config);
    try std.testing.expectEqualStrings("false", a.alterar_config.valor);
}

test "comando .imagem: toggle off→on" {
    const m = Mensagem{ .conteudo = .{ .comando = .imagem } };
    const c = Config{ .media_imagem = false };
    const a = processar(m, c);
    try std.testing.expectEqualStrings("media_imagem", a.alterar_config.campo);
    try std.testing.expectEqualStrings("true", a.alterar_config.valor);
}

test "comando .curto → alterar_config modo_descricao=curto" {
    const m = Mensagem{ .conteudo = .{ .comando = .curto } };
    const a = processar(m, .{});
    try std.testing.expect(a == .alterar_config);
    try std.testing.expectEqualStrings("modo_descricao", a.alterar_config.campo);
    try std.testing.expectEqualStrings("curto", a.alterar_config.valor);
}

test "comando .cego → ativar_modo_cego" {
    const m = Mensagem{ .conteudo = .{ .comando = .cego } };
    try std.testing.expect(processar(m, .{}) == .ativar_modo_cego);
}

// --- Prompt ---

test "comando .prompt listar → listar_prompts" {
    const cmd = Comando{ .prompt = .listar };
    const m = Mensagem{ .conteudo = .{ .comando = cmd } };
    try std.testing.expect(processar(m, .{}) == .listar_prompts);
}

test "comando .prompt limpar → limpar_prompt_ativo" {
    const cmd = Comando{ .prompt = .limpar };
    const m = Mensagem{ .conteudo = .{ .comando = cmd } };
    try std.testing.expect(processar(m, .{}) == .limpar_prompt_ativo);
}

test "comando .prompt criar → salvar_prompt" {
    const cmd = Comando{ .prompt = .{ .criar = .{ .nome = "chef", .valor = "Seja um chef." } } };
    const m = Mensagem{ .conteudo = .{ .comando = cmd } };
    const a = processar(m, .{});
    try std.testing.expect(a == .salvar_prompt);
    try std.testing.expectEqualStrings("chef", a.salvar_prompt.nome);
    try std.testing.expectEqualStrings("Seja um chef.", a.salvar_prompt.conteudo);
}

test "comando .prompt usar → ativar_prompt" {
    const cmd = Comando{ .prompt = .{ .usar = "chef" } };
    const m = Mensagem{ .conteudo = .{ .comando = cmd } };
    const a = processar(m, .{});
    try std.testing.expect(a == .ativar_prompt);
    try std.testing.expectEqualStrings("chef", a.ativar_prompt);
}

test "comando .prompt deletar → deletar_prompt" {
    const cmd = Comando{ .prompt = .{ .deletar = "chef" } };
    const m = Mensagem{ .conteudo = .{ .comando = cmd } };
    const a = processar(m, .{});
    try std.testing.expect(a == .deletar_prompt);
    try std.testing.expectEqualStrings("chef", a.deletar_prompt);
}

test "comando .prompt gerar → invocar_ia (Gemini gera prompt)" {
    const cmd = Comando{ .prompt = .{ .gerar = "Crie um prompt para revisar textos." } };
    const m = Mensagem{ .conteudo = .{ .comando = cmd } };
    const a = processar(m, .{});
    try std.testing.expect(a == .invocar_ia);
    try std.testing.expectEqual(false, a.invocar_ia.incluir_historico);
}

// --- Config ---

test "comando .config definir → alterar_config" {
    const cmd = Comando{ .config = .{ .definir = .{ .nome = "temperature", .valor = "0.7" } } };
    const m = Mensagem{ .conteudo = .{ .comando = cmd } };
    const a = processar(m, .{});
    try std.testing.expect(a == .alterar_config);
    try std.testing.expectEqualStrings("temperature", a.alterar_config.campo);
    try std.testing.expectEqualStrings("0.7", a.alterar_config.valor);
}

test "comando .config obter → responder (shell busca valor)" {
    const cmd = Comando{ .config = .{ .obter = "temperature" } };
    const m = Mensagem{ .conteudo = .{ .comando = cmd } };
    // .config get precisa de DB → core sinaliza com obter_status?
    // Definimos: .config get retorna uma Acao especial = .responder vazio
    // e o shell substitui pelo valor real.
    // Por ora: responder com string vazia (shell completa).
    const a = processar(m, .{});
    try std.testing.expect(a == .responder);
}

test "comando .usuarios → listar_usuarios" {
    // .usuarios ainda não está em Comando — será adicionado.
    // Por ora, .desconhecido retorna .ignorar (comportamento correto).
    const cmd_d = Comando{ .desconhecido = ".usuarios" };
    const m = Mensagem{ .conteudo = .{ .comando = cmd_d } };
    try std.testing.expect(processar(m, .{}) == .ignorar);
}
