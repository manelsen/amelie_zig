// infra/cache_ia.zig
// Cache de respostas de IA — evita chamadas redundantes para prompts idênticos.
//
// Thread-safe. Keyed por Wyhash(prompt ++ "\x00" ++ system_prompt).
// TTL padrão: 3600s. Máximo padrão: 500 entradas (evicta a mais antiga).

const std = @import("std");

pub const CacheConfig = struct {
    ttl_s:       i64   = 3600,  // 1 hora
    max_entries: usize = 500,
};

const Entrada = struct {
    resposta:  []const u8,
    timestamp: i64,
};

pub const CacheIA = struct {
    mapa:      std.AutoHashMap(u64, Entrada),
    config:    CacheConfig,
    mutex:     std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: CacheConfig) CacheIA {
        return .{
            .mapa      = std.AutoHashMap(u64, Entrada).init(allocator),
            .config    = config,
            .mutex     = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CacheIA) void {
        var it = self.mapa.valueIterator();
        while (it.next()) |v| {
            self.allocator.free(v.resposta);
        }
        self.mapa.deinit();
    }

    /// Retorna cópia da resposta cacheada (caller libera), ou null se miss/expirado.
    pub fn obter(
        self:      *CacheIA,
        prompt:    []const u8,
        sp:        ?[]const u8,
        allocator: std.mem.Allocator,
    ) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const chave = hashChave(prompt, sp);
        const entrada = self.mapa.get(chave) orelse return null;

        const agora = std.time.timestamp();
        if (agora - entrada.timestamp > self.config.ttl_s) {
            self.allocator.free(entrada.resposta);
            _ = self.mapa.remove(chave);
            return null;
        }
        return allocator.dupe(u8, entrada.resposta) catch null;
    }

    /// Insere resposta no cache. NOP silencioso em caso de falha de alocação.
    pub fn inserir(
        self:     *CacheIA,
        prompt:   []const u8,
        sp:       ?[]const u8,
        resposta: []const u8,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.mapa.count() >= self.config.max_entries) {
            self.evictarMaisAntigo();
        }

        const chave = hashChave(prompt, sp);
        const resp_dup = self.allocator.dupe(u8, resposta) catch return;

        // Sobrescreve entrada antiga (libera a anterior)
        if (self.mapa.getPtr(chave)) |old_ptr| {
            self.allocator.free(old_ptr.resposta);
            old_ptr.* = Entrada{
                .resposta  = resp_dup,
                .timestamp = std.time.timestamp(),
            };
            return;
        }

        self.mapa.put(chave, Entrada{
            .resposta  = resp_dup,
            .timestamp = std.time.timestamp(),
        }) catch {
            self.allocator.free(resp_dup);
        };
    }

    /// Remove entradas expiradas. Chamado periodicamente pela Telemetria.
    pub fn limparExpirados(self: *CacheIA) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const agora = std.time.timestamp();

        var a_remover = std.ArrayListUnmanaged(u64){};
        defer a_remover.deinit(self.allocator);

        var it = self.mapa.iterator();
        while (it.next()) |entry| {
            if (agora - entry.value_ptr.timestamp > self.config.ttl_s) {
                a_remover.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (a_remover.items) |k| {
            if (self.mapa.fetchRemove(k)) |kv| {
                self.allocator.free(kv.value.resposta);
            }
        }
    }

    pub fn contagem(self: *CacheIA) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.mapa.count();
    }

    // --- privados ---

    fn hashChave(prompt: []const u8, sp: ?[]const u8) u64 {
        var h = std.hash.Wyhash.init(0xABCDEF1234);
        h.update(prompt);
        h.update("\x00");
        if (sp) |s| h.update(s);
        return h.final();
    }

    fn evictarMaisAntigo(self: *CacheIA) void {
        var oldest_key: ?u64  = null;
        var oldest_ts:  i64   = std.math.maxInt(i64);
        var it = self.mapa.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.timestamp < oldest_ts) {
                oldest_ts  = entry.value_ptr.timestamp;
                oldest_key = entry.key_ptr.*;
            }
        }
        if (oldest_key) |k| {
            if (self.mapa.fetchRemove(k)) |kv| {
                self.allocator.free(kv.value.resposta);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

test "CacheIA: miss em cache vazio" {
    var c = CacheIA.init(testing.allocator, .{});
    defer c.deinit();

    try testing.expectEqual(@as(?[]const u8, null), c.obter("prompt", null, testing.allocator));
}

test "CacheIA: inserir e obter hit" {
    var c = CacheIA.init(testing.allocator, .{});
    defer c.deinit();

    c.inserir("prompt", null, "resposta cacheada");
    const r = c.obter("prompt", null, testing.allocator);
    defer if (r) |v| testing.allocator.free(v);

    try testing.expect(r != null);
    try testing.expectEqualStrings("resposta cacheada", r.?);
}

test "CacheIA: chave difere por system_prompt" {
    var c = CacheIA.init(testing.allocator, .{});
    defer c.deinit();

    c.inserir("prompt", null,    "sem sp");
    c.inserir("prompt", "sys1", "com sp1");

    const r1 = c.obter("prompt", null,    testing.allocator);
    defer if (r1) |v| testing.allocator.free(v);
    const r2 = c.obter("prompt", "sys1", testing.allocator);
    defer if (r2) |v| testing.allocator.free(v);

    try testing.expectEqualStrings("sem sp",  r1.?);
    try testing.expectEqualStrings("com sp1", r2.?);
}

test "CacheIA: sobrescreve entrada existente" {
    var c = CacheIA.init(testing.allocator, .{});
    defer c.deinit();

    c.inserir("p", null, "v1");
    c.inserir("p", null, "v2");

    const r = c.obter("p", null, testing.allocator);
    defer if (r) |v| testing.allocator.free(v);
    try testing.expectEqualStrings("v2", r.?);
}

test "CacheIA: evicta mais antigo quando cheio" {
    var c = CacheIA.init(testing.allocator, .{ .max_entries = 2 });
    defer c.deinit();

    c.inserir("p1", null, "r1");
    std.time.sleep(1 * std.time.ns_per_ms); // garante timestamps distintos
    c.inserir("p2", null, "r2");
    c.inserir("p3", null, "r3"); // força evicção de p1

    try testing.expectEqual(@as(usize, 2), c.contagem());
    try testing.expectEqual(@as(?[]const u8, null), c.obter("p1", null, testing.allocator));
}

test "CacheIA: limparExpirados remove apenas expirados" {
    var c = CacheIA.init(testing.allocator, .{ .ttl_s = 0 });
    defer c.deinit();

    c.inserir("p", null, "r");
    std.time.sleep(2 * std.time.ns_per_ms);
    c.limparExpirados();

    try testing.expectEqual(@as(usize, 0), c.contagem());
}
