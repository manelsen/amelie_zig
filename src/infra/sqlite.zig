// infra/sqlite.zig
// Camada de persistência: wrapper fino sobre o C sqlite3.
//
// Tabelas:
//   config   (chat_id, media_imagem, media_audio, media_video, media_documento,
//             modo_descricao, usar_legenda, system_prompt, prompt_ativo)
//   prompts  (chat_id, nome, conteudo)      PRIMARY KEY (chat_id, nome)
//   historico(id, chat_id, role, conteudo, timestamp)
//   usuarios (jid, nome, eh_admin, primeiro_contato)
//
// Uso:
//   var db = try Db.open("amelie.db", allocator);
//   defer db.deinit();
//   try db.criarEsquema();
//   try db.salvarConfig(config);
//   const cfg = try db.carregarConfig("5531@s.whatsapp.net", allocator);

const std = @import("std");
const c = @cImport(@cInclude("sqlite3.h"));
const cfg_m = @import("../dominio/config.zig");

pub const Config = cfg_m.Config;
pub const ModoDescricao = cfg_m.ModoDescricao;
pub const Provider = cfg_m.Provider;

pub const ErroDb = error{
    AbrirFalhou,
    PrepararFalhou,
    ExecFalhou,
    EsquemaFalhou,
};

// ---------------------------------------------------------------------------
// Entrada de histórico
// ---------------------------------------------------------------------------

pub const EntradaHistorico = struct {
    role: []const u8,
    conteudo: []const u8,
    timestamp: i64,
};

pub const EntradaUsuario = struct {
    jid: []const u8,
    nome: []const u8,
    eh_admin: bool,
};

pub const Transacao = struct {
    id: []const u8,
    chat_id: []const u8,
    conteudo: []const u8,
    status: []const u8,
    timestamp: i64,
    tentativas: i64,
    proxima_tentativa: i64,
};

// ---------------------------------------------------------------------------
// Db — handle principal
// ---------------------------------------------------------------------------

pub const Db = struct {
    handle: ?*c.sqlite3,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    /// Abre (ou cria) arquivo de banco de dados.
    pub fn open(path: [:0]const u8, allocator: std.mem.Allocator) !Db {
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path, &handle) != c.SQLITE_OK) return ErroDb.AbrirFalhou;
        return .{ .handle = handle.?, .allocator = allocator };
    }

    /// Banco em memória — ideal para testes.
    pub fn openMemory(allocator: std.mem.Allocator) !Db {
        return open(":memory:", allocator);
    }

    pub fn deinit(self: *Db) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = c.sqlite3_close(self.handle);
    }

    // -----------------------------------------------------------------------
    // Esquema
    // -----------------------------------------------------------------------

    pub fn criarEsquema(self: *Db) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql =
            \\CREATE TABLE IF NOT EXISTS config (
            \\  chat_id         TEXT PRIMARY KEY,
            \\  media_imagem    INTEGER NOT NULL,
            \\  media_audio     INTEGER NOT NULL,
            \\  media_video     INTEGER NOT NULL,
            \\  media_documento INTEGER NOT NULL,
            \\  modo_descricao  TEXT NOT NULL,
            \\  usar_legenda    INTEGER NOT NULL,
            \\  provider        TEXT NOT NULL DEFAULT 'gemini',
            \\  system_prompt   TEXT NOT NULL,
            \\  prompt_ativo    TEXT
            \\);
            \\CREATE TABLE IF NOT EXISTS prompts (
            \\  chat_id  TEXT NOT NULL,
            \\  nome     TEXT NOT NULL,
            \\  conteudo TEXT NOT NULL,
            \\  PRIMARY KEY (chat_id, nome)
            \\);
            \\CREATE TABLE IF NOT EXISTS historico (
            \\  id        INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  chat_id   TEXT    NOT NULL,
            \\  role      TEXT    NOT NULL,
            \\  conteudo  TEXT    NOT NULL,
            \\  timestamp INTEGER NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_historico_chat
            \\  ON historico(chat_id, id DESC);
            \\CREATE TABLE IF NOT EXISTS usuarios (
            \\  jid              TEXT PRIMARY KEY,
            \\  nome             TEXT NOT NULL DEFAULT '',
            \\  eh_admin         INTEGER NOT NULL DEFAULT 0,
            \\  primeiro_contato INTEGER NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS transacoes (
            \\  id        TEXT PRIMARY KEY,
            \\  chat_id   TEXT NOT NULL,
            \\  conteudo  TEXT NOT NULL,
            \\  status    TEXT NOT NULL,
            \\  timestamp INTEGER NOT NULL,
            \\  tentativas INTEGER NOT NULL DEFAULT 0,
            \\  proxima_tentativa INTEGER NOT NULL DEFAULT 0
            \\);
        ;
        if (c.sqlite3_exec(self.handle, sql, null, null, null) != c.SQLITE_OK)
            return ErroDb.EsquemaFalhou;
    }

    // -----------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------

    /// Salva (INSERT OR REPLACE) a configuração de um chat.
    pub fn salvarConfig(self: *Db, cfg: Config) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql =
            \\INSERT OR REPLACE INTO config (
            \\   chat_id, media_imagem, media_audio, media_video, media_documento,
            \\   modo_descricao, usar_legenda, provider, system_prompt, prompt_ativo)
            \\VALUES (?,?,?,?,?,?,?,?,?,?)
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, cfg.chat_id);
        bindInt(stmt, 2, if (cfg.media_imagem) 1 else 0);
        bindInt(stmt, 3, if (cfg.media_audio) 1 else 0);
        bindInt(stmt, 4, if (cfg.media_video) 1 else 0);
        bindInt(stmt, 5, if (cfg.media_documento) 1 else 0);
        bindText(stmt, 6, cfg.modo_descricao.toStr());
        bindInt(stmt, 7, if (cfg.usar_legenda) 1 else 0);
        bindText(stmt, 8, cfg.provider.toStr());
        bindText(stmt, 9, cfg.system_prompt);
        if (cfg.prompt_ativo) |pa| bindText(stmt, 10, pa) else _ = c.sqlite3_bind_null(stmt, 10);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return ErroDb.ExecFalhou;
    }

    /// Carrega a configuração de um chat. Retorna null se não existir.
    /// Strings retornadas são alocadas — caller deve liberar com `allocator.free`.
    pub fn carregarConfig(self: *Db, chat_id: []const u8, allocator: std.mem.Allocator) !?Config {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql =
            \\SELECT media_imagem, media_audio, media_video, media_documento,
            \\       modo_descricao, usar_legenda, provider, system_prompt, prompt_ativo
            \\FROM config WHERE chat_id = ?
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, chat_id);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        const sp_raw = columnText(stmt, 7);
        const pa_raw = columnTextOpt(stmt, 8);

        return Config{
            .chat_id = chat_id,
            .media_imagem = c.sqlite3_column_int(stmt, 0) != 0,
            .media_audio = c.sqlite3_column_int(stmt, 1) != 0,
            .media_video = c.sqlite3_column_int(stmt, 2) != 0,
            .media_documento = c.sqlite3_column_int(stmt, 3) != 0,
            .modo_descricao = ModoDescricao.fromStr(columnText(stmt, 4)),
            .usar_legenda = c.sqlite3_column_int(stmt, 5) != 0,
            .provider = Provider.fromStr(columnText(stmt, 6)),
            .system_prompt = try allocator.dupe(u8, sp_raw),
            .prompt_ativo = if (pa_raw) |pa| try allocator.dupe(u8, pa) else null,
        };
    }

    /// Deleta a configuração de um chat (reset).
    pub fn deletarConfig(self: *Db, chat_id: []const u8) !void {
        try self.exec("DELETE FROM config WHERE chat_id = ?", chat_id);
    }

    // -----------------------------------------------------------------------
    // Prompts
    // -----------------------------------------------------------------------

    pub fn salvarPrompt(
        self: *Db,
        chat_id: []const u8,
        nome: []const u8,
        conteudo: []const u8,
    ) !void {
        const sql =
            \\INSERT OR REPLACE INTO prompts (chat_id, nome, conteudo)
            \\VALUES (?,?,?)
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, chat_id);
        bindText(stmt, 2, nome);
        bindText(stmt, 3, conteudo);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return ErroDb.ExecFalhou;
    }

    /// Retorna conteúdo do prompt alocado — caller libera. null se não existe.
    pub fn obterPrompt(
        self: *Db,
        chat_id: []const u8,
        nome: []const u8,
        allocator: std.mem.Allocator,
    ) !?[]const u8 {
        const sql = "SELECT conteudo FROM prompts WHERE chat_id=? AND nome=?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, chat_id);
        bindText(stmt, 2, nome);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return try allocator.dupe(u8, columnText(stmt, 0));
    }

    /// Lista nomes dos prompts de um chat. Caller libera cada item e o slice.
    pub fn listarPrompts(
        self: *Db,
        chat_id: []const u8,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        const sql = "SELECT nome FROM prompts WHERE chat_id=? ORDER BY nome";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, chat_id);

        var lista = std.ArrayListUnmanaged([]const u8){};
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try lista.append(allocator, try allocator.dupe(u8, columnText(stmt, 0)));
        }
        return lista.toOwnedSlice(allocator);
    }

    pub fn deletarPrompt(self: *Db, chat_id: []const u8, nome: []const u8) !void {
        const sql = "DELETE FROM prompts WHERE chat_id=? AND nome=?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, chat_id);
        bindText(stmt, 2, nome);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return ErroDb.ExecFalhou;
    }

    // -----------------------------------------------------------------------
    // Histórico
    // -----------------------------------------------------------------------

    pub fn adicionarHistorico(
        self: *Db,
        chat_id: []const u8,
        role: []const u8,
        conteudo: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql =
            \\INSERT INTO historico (chat_id, role, conteudo, timestamp)
            \\VALUES (?,?,?,?)
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, chat_id);
        bindText(stmt, 2, role);
        bindText(stmt, 3, conteudo);
        _ = c.sqlite3_bind_int64(stmt, 4, std.time.timestamp());

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return ErroDb.ExecFalhou;
    }

    /// Retorna as últimas `limite` entradas em ordem cronológica.
    /// Caller libera cada slice e o array.
    pub fn obterHistorico(
        self: *Db,
        chat_id: []const u8,
        limite: u32,
        allocator: std.mem.Allocator,
    ) ![]EntradaHistorico {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql =
            \\SELECT role, conteudo, timestamp FROM (
            \\  SELECT id, role, conteudo, timestamp FROM historico
            \\  WHERE chat_id=? ORDER BY id DESC LIMIT ?
            \\) ORDER BY id ASC
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, chat_id);
        _ = c.sqlite3_bind_int(stmt, 2, @intCast(limite));

        var lista = std.ArrayListUnmanaged(EntradaHistorico){};
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try lista.append(allocator, .{
                .role = try allocator.dupe(u8, columnText(stmt, 0)),
                .conteudo = try allocator.dupe(u8, columnText(stmt, 1)),
                .timestamp = c.sqlite3_column_int64(stmt, 2),
            });
        }
        return lista.toOwnedSlice(allocator);
    }

    pub fn limparHistorico(self: *Db, chat_id: []const u8) !void {
        try self.exec("DELETE FROM historico WHERE chat_id = ?", chat_id);
    }

    // -----------------------------------------------------------------------
    // Usuários
    // -----------------------------------------------------------------------

    pub fn registrarUsuario(
        self: *Db,
        jid: []const u8,
        nome: []const u8,
        eh_admin: bool,
    ) !void {
        const sql =
            \\INSERT OR IGNORE INTO usuarios (jid, nome, eh_admin, primeiro_contato)
            \\VALUES (?,?,?,?)
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, jid);
        bindText(stmt, 2, nome);
        bindInt(stmt, 3, if (eh_admin) 1 else 0);
        _ = c.sqlite3_bind_int64(stmt, 4, std.time.timestamp());

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return ErroDb.ExecFalhou;
    }

    /// Lista todos os usuários registrados. Caller libera cada slice e o array.
    pub fn listarUsuarios(self: *Db, allocator: std.mem.Allocator) ![]EntradaUsuario {
        const sql = "SELECT jid, nome, eh_admin FROM usuarios ORDER BY primeiro_contato ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        var lista = std.ArrayListUnmanaged(EntradaUsuario){};
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try lista.append(allocator, .{
                .jid = try allocator.dupe(u8, columnText(stmt, 0)),
                .nome = try allocator.dupe(u8, columnText(stmt, 1)),
                .eh_admin = c.sqlite3_column_int(stmt, 2) != 0,
            });
        }
        return lista.toOwnedSlice(allocator);
    }

    pub fn contarUsuarios(self: *Db) !i64 {
        const sql = "SELECT COUNT(*) FROM usuarios";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return c.sqlite3_column_int64(stmt, 0);
    }

    // -----------------------------------------------------------------------
    // Transações (Acks)
    // -----------------------------------------------------------------------

    pub fn registrarTransacao(
        self: *Db,
        id: []const u8,
        chat_id: []const u8,
        conteudo: []const u8,
        status: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql =
            \\INSERT INTO transacoes (id, chat_id, conteudo, status, timestamp, tentativas, proxima_tentativa)
            \\VALUES (?,?,?,?,?,0,?)
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, id);
        bindText(stmt, 2, chat_id);
        bindText(stmt, 3, conteudo);
        bindText(stmt, 4, status);
        _ = c.sqlite3_bind_int64(stmt, 5, std.time.timestamp());
        _ = c.sqlite3_bind_int64(stmt, 6, std.time.timestamp()); // proxima = agora

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return ErroDb.ExecFalhou;
    }

    pub fn atualizarTransacaoStatus(
        self: *Db,
        id: []const u8,
        status: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql = "UPDATE transacoes SET status = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        bindText(stmt, 1, status);
        bindText(stmt, 2, id);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return ErroDb.ExecFalhou;
    }

    pub fn obterTransacoesPendentes(self: *Db, allocator: std.mem.Allocator) ![]Transacao {
        self.mutex.lock();
        defer self.mutex.unlock();
        const agora = std.time.timestamp();
        // pega as pendentes onde proxima_tentativa <= agora (e tenta no máximo 3 vezes)
        const sql = "SELECT id, chat_id, conteudo, status, timestamp, tentativas, proxima_tentativa FROM transacoes WHERE status = 'pending' AND proxima_tentativa <= ? AND tentativas < 3 ORDER BY timestamp ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, agora);

        var lista = std.ArrayListUnmanaged(Transacao){};
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try lista.append(allocator, .{
                .id = try allocator.dupe(u8, columnText(stmt, 0)),
                .chat_id = try allocator.dupe(u8, columnText(stmt, 1)),
                .conteudo = try allocator.dupe(u8, columnText(stmt, 2)),
                .status = try allocator.dupe(u8, columnText(stmt, 3)),
                .timestamp = c.sqlite3_column_int64(stmt, 4),
                .tentativas = c.sqlite3_column_int64(stmt, 5),
                .proxima_tentativa = c.sqlite3_column_int64(stmt, 6),
            });
        }
        return lista.toOwnedSlice(allocator);
    }

    pub fn registrarTentativa(self: *Db, id: []const u8, nova_proxima: i64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql = "UPDATE transacoes SET tentativas = tentativas + 1, proxima_tentativa = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, nova_proxima);
        bindText(stmt, 2, id);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return ErroDb.ExecFalhou;
    }

    // -----------------------------------------------------------------------
    // Helpers internos
    // -----------------------------------------------------------------------

    fn exec(self: *Db, sql: [*:0]const u8, param: []const u8) !void {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null) != c.SQLITE_OK)
            return ErroDb.PrepararFalhou;
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, param);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return ErroDb.ExecFalhou;
    }
};

// ---------------------------------------------------------------------------
// Helpers C ↔ Zig
// ---------------------------------------------------------------------------

fn bindText(stmt: ?*c.sqlite3_stmt, col: c_int, s: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, col, s.ptr, @intCast(s.len), c.SQLITE_STATIC);
}

fn bindInt(stmt: ?*c.sqlite3_stmt, col: c_int, v: c_int) void {
    _ = c.sqlite3_bind_int(stmt, col, v);
}

fn columnText(stmt: ?*c.sqlite3_stmt, col: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    if (ptr == null) return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    return ptr[0..len];
}

fn columnTextOpt(stmt: ?*c.sqlite3_stmt, col: c_int) ?[]const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    if (ptr == null) return null;
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    return ptr[0..len];
}

// ---------------------------------------------------------------------------
// Testes — banco em memória, sem arquivo
// ---------------------------------------------------------------------------

const testing = std.testing;

test "criarEsquema: sem erro" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();
    // idempotente
    try db.criarEsquema();
}

test "config: salvar e carregar" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    const cfg = Config{
        .chat_id = "5531@s.whatsapp.net",
        .media_imagem = true,
        .media_audio = true,
        .media_video = false,
        .media_documento = true,
        .modo_descricao = .cego,
        .usar_legenda = true,
        .system_prompt = "Seja breve.",
        .prompt_ativo = "meu-prompt",
    };
    try db.salvarConfig(cfg);

    const loaded = (try db.carregarConfig("5531@s.whatsapp.net", testing.allocator)).?;
    defer testing.allocator.free(loaded.system_prompt);
    defer if (loaded.prompt_ativo) |pa| testing.allocator.free(pa);

    try testing.expectEqual(true, loaded.media_imagem);
    try testing.expectEqual(true, loaded.media_audio);
    try testing.expectEqual(false, loaded.media_video);
    try testing.expectEqual(.cego, loaded.modo_descricao);
    try testing.expectEqual(true, loaded.usar_legenda);
    try testing.expectEqualStrings("Seja breve.", loaded.system_prompt);
    try testing.expectEqualStrings("meu-prompt", loaded.prompt_ativo.?);
}

test "config: inexistente retorna null" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    const r = try db.carregarConfig("ninguem@s.whatsapp.net", testing.allocator);
    try testing.expectEqual(@as(?Config, null), r);
}

test "config: prompt_ativo null persiste como null" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    const cfg = Config{ .chat_id = "chat1", .prompt_ativo = null };
    try db.salvarConfig(cfg);

    const loaded = (try db.carregarConfig("chat1", testing.allocator)).?;
    defer testing.allocator.free(loaded.system_prompt);

    try testing.expectEqual(@as(?[]const u8, null), loaded.prompt_ativo);
}

test "config: deletarConfig remove registro" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    try db.salvarConfig(Config{ .chat_id = "chat2" });
    try db.deletarConfig("chat2");

    const r = try db.carregarConfig("chat2", testing.allocator);
    try testing.expectEqual(@as(?Config, null), r);
}

test "config: salvarConfig é idempotente (UPDATE semântico)" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    try db.salvarConfig(Config{ .chat_id = "chat3", .media_audio = false });
    try db.salvarConfig(Config{ .chat_id = "chat3", .media_audio = true });

    const loaded = (try db.carregarConfig("chat3", testing.allocator)).?;
    defer testing.allocator.free(loaded.system_prompt);
    try testing.expectEqual(true, loaded.media_audio);
}

test "prompts: salvar, obter, listar, deletar" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    const chat = "chat_prompt";
    try db.salvarPrompt(chat, "resumo", "Resuma em 3 pontos.");
    try db.salvarPrompt(chat, "tecnico", "Use linguagem técnica.");

    // obter existente
    const conteudo = (try db.obterPrompt(chat, "resumo", testing.allocator)).?;
    defer testing.allocator.free(conteudo);
    try testing.expectEqualStrings("Resuma em 3 pontos.", conteudo);

    // obter inexistente
    const nada = try db.obterPrompt(chat, "inexistente", testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), nada);

    // listar
    const lista = try db.listarPrompts(chat, testing.allocator);
    defer {
        for (lista) |s| testing.allocator.free(s);
        testing.allocator.free(lista);
    }
    try testing.expectEqual(@as(usize, 2), lista.len);
    try testing.expectEqualStrings("resumo", lista[0]);
    try testing.expectEqualStrings("tecnico", lista[1]);

    // deletar
    try db.deletarPrompt(chat, "resumo");
    const lista2 = try db.listarPrompts(chat, testing.allocator);
    defer {
        for (lista2) |s| testing.allocator.free(s);
        testing.allocator.free(lista2);
    }
    try testing.expectEqual(@as(usize, 1), lista2.len);
}

test "prompts: listar chat vazio retorna slice vazio" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    const lista = try db.listarPrompts("nenhum", testing.allocator);
    defer testing.allocator.free(lista);
    try testing.expectEqual(@as(usize, 0), lista.len);
}

test "historico: adicionar e obter em ordem cronológica" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    const chat = "hist_chat";
    try db.adicionarHistorico(chat, "user", "Oi!");
    try db.adicionarHistorico(chat, "model", "Olá, como posso ajudar?");
    try db.adicionarHistorico(chat, "user", "Me conta uma piada.");

    const hist = try db.obterHistorico(chat, 10, testing.allocator);
    defer {
        for (hist) |e| {
            testing.allocator.free(e.role);
            testing.allocator.free(e.conteudo);
        }
        testing.allocator.free(hist);
    }

    try testing.expectEqual(@as(usize, 3), hist.len);
    try testing.expectEqualStrings("user", hist[0].role);
    try testing.expectEqualStrings("Oi!", hist[0].conteudo);
    try testing.expectEqualStrings("model", hist[1].role);
}

test "historico: limite funciona" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    const chat = "hist_limit";
    try db.adicionarHistorico(chat, "user", "msg1");
    try db.adicionarHistorico(chat, "model", "msg2");
    try db.adicionarHistorico(chat, "user", "msg3");

    const hist = try db.obterHistorico(chat, 2, testing.allocator);
    defer {
        for (hist) |e| {
            testing.allocator.free(e.role);
            testing.allocator.free(e.conteudo);
        }
        testing.allocator.free(hist);
    }
    // As 2 mais recentes, em ordem cronológica
    try testing.expectEqual(@as(usize, 2), hist.len);
    try testing.expectEqualStrings("msg2", hist[0].conteudo);
    try testing.expectEqualStrings("msg3", hist[1].conteudo);
}

test "historico: limpar apaga apenas o chat correto" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    try db.adicionarHistorico("chat_a", "user", "a");
    try db.adicionarHistorico("chat_b", "user", "b");

    try db.limparHistorico("chat_a");

    const ha = try db.obterHistorico("chat_a", 10, testing.allocator);
    defer testing.allocator.free(ha);
    try testing.expectEqual(@as(usize, 0), ha.len);

    const hb = try db.obterHistorico("chat_b", 10, testing.allocator);
    defer {
        for (hb) |e| {
            testing.allocator.free(e.role);
            testing.allocator.free(e.conteudo);
        }
        testing.allocator.free(hb);
    }
    try testing.expectEqual(@as(usize, 1), hb.len);
}

test "usuarios: registrar e contar" {
    var db = try Db.openMemory(testing.allocator);
    defer db.deinit();
    try db.criarEsquema();

    try db.registrarUsuario("5531@s.whatsapp.net", "João", false);
    try db.registrarUsuario("5532@s.whatsapp.net", "Admin", true);

    try testing.expectEqual(@as(i64, 2), try db.contarUsuarios());

    // INSERT OR IGNORE — não duplica
    try db.registrarUsuario("5531@s.whatsapp.net", "João Repetido", false);
    try testing.expectEqual(@as(i64, 2), try db.contarUsuarios());
}
