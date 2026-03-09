// infra/cache_mensagens.zig
// Deduplicação de mensagens — impede reprocessamento de mensagens duplicadas.
//
// Thread-safe. TTL padrão: 15 minutos (igual ao amelie/JS).
// Limpeza periódica chamada pela Telemetria.

const std = @import("std");

pub const CacheMensagens = struct {
    mapa:      std.AutoHashMap(u64, i64), // hash(msg_id) → timestamp_ms
    mutex:     std.Thread.Mutex,
    allocator: std.mem.Allocator,
    ttl_ms:    i64 = 15 * 60 * 1000, // 15 minutos

    pub fn init(allocator: std.mem.Allocator) CacheMensagens {
        return .{
            .mapa      = std.AutoHashMap(u64, i64).init(allocator),
            .mutex     = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CacheMensagens) void {
        self.mapa.deinit();
    }

    /// Retorna true se a mensagem é nova (não vista no TTL). false = duplicata.
    /// Registra automaticamente se nova.
    pub fn eNova(self: *CacheMensagens, msg_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const agora = std.time.milliTimestamp();
        const chave = std.hash.Wyhash.hash(0, msg_id);

        if (self.mapa.get(chave)) |ts| {
            if (agora - ts < self.ttl_ms) return false; // duplicata dentro do TTL
        }

        self.mapa.put(chave, agora) catch {};
        return true;
    }

    /// Remove entradas mais velhas que TTL. Chamado periodicamente pela Telemetria.
    pub fn limpar(self: *CacheMensagens) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const agora = std.time.milliTimestamp();

        var a_remover = std.ArrayListUnmanaged(u64){};
        defer a_remover.deinit(self.allocator);

        var it = self.mapa.iterator();
        while (it.next()) |entry| {
            if (agora - entry.value_ptr.* >= self.ttl_ms) {
                a_remover.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (a_remover.items) |k| _ = self.mapa.remove(k);
    }

    pub fn contagem(self: *CacheMensagens) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.mapa.count();
    }
};

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

test "CacheMensagens: primeira ocorrência é nova" {
    var c = CacheMensagens.init(testing.allocator);
    defer c.deinit();

    try testing.expect(c.eNova("msg_abc_123"));
}

test "CacheMensagens: segunda ocorrência dentro do TTL é duplicata" {
    var c = CacheMensagens.init(testing.allocator);
    defer c.deinit();

    try testing.expect(c.eNova("msg_dup"));
    try testing.expect(!c.eNova("msg_dup")); // duplicata
}

test "CacheMensagens: mensagens diferentes são independentes" {
    var c = CacheMensagens.init(testing.allocator);
    defer c.deinit();

    try testing.expect(c.eNova("msg_1"));
    try testing.expect(c.eNova("msg_2"));
    try testing.expect(!c.eNova("msg_1")); // duplicata
    try testing.expect(!c.eNova("msg_2")); // duplicata
}

test "CacheMensagens: limpar remove entradas expiradas" {
    var c = CacheMensagens{ .mapa = std.AutoHashMap(u64, i64).init(testing.allocator), .mutex = .{}, .allocator = testing.allocator, .ttl_ms = 0 };
    defer c.deinit();

    _ = c.eNova("msg_exp");
    std.time.sleep(1 * std.time.ns_per_ms);
    c.limpar();

    try testing.expectEqual(@as(usize, 0), c.contagem());
}
