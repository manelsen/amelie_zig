// infra/telemetria.zig
// Monitoramento periódico de memória e uptime.
// Thread de background que a cada N segundos:
//   - Loga RSS + uptime
//   - Limpa entradas expiradas do cache_ia e cache_mensagens

const std = @import("std");

const cache_ia_m       = @import("cache_ia.zig");
const cache_mens_m     = @import("cache_mensagens.zig");

pub const TelemetriaConfig = struct {
    intervalo_s: u64 = 300, // 5 minutos (igual ao amelie/JS)
};

pub const Telemetria = struct {
    config:          TelemetriaConfig,
    inicio:          i64,
    encerrando:      bool,
    mutex:           std.Thread.Mutex,
    cache_ia:        ?*cache_ia_m.CacheIA,
    cache_mensagens: ?*cache_mens_m.CacheMensagens,

    pub fn init(
        config:          TelemetriaConfig,
        cache_ia:        ?*cache_ia_m.CacheIA,
        cache_mensagens: ?*cache_mens_m.CacheMensagens,
    ) Telemetria {
        return .{
            .config          = config,
            .inicio          = std.time.timestamp(),
            .encerrando      = false,
            .mutex           = .{},
            .cache_ia        = cache_ia,
            .cache_mensagens = cache_mensagens,
        };
    }

    /// Inicia thread de telemetria. Caller deve chamar thread.detach() ou thread.join().
    pub fn iniciar(self: *Telemetria) !std.Thread {
        return std.Thread.spawn(.{}, monitorar, .{self});
    }

    pub fn parar(self: *Telemetria) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.encerrando = true;
    }

    fn monitorar(self: *Telemetria) void {
        std.log.info("[Telemetria] Monitoramento iniciado (intervalo={d}s).", .{self.config.intervalo_s});
        while (true) {
            std.time.sleep(self.config.intervalo_s * std.time.ns_per_s);

            self.mutex.lock();
            const enc = self.encerrando;
            self.mutex.unlock();
            if (enc) break;

            self.registrarStats();
            self.limparCaches();
        }
        std.log.info("[Telemetria] Monitoramento encerrado.", .{});
    }

    fn registrarStats(self: *Telemetria) void {
        const uptime  = std.time.timestamp() - self.inicio;
        const rss_kb  = lerRssKb() orelse 0;
        const n_ia    = if (self.cache_ia)        |c| c.contagem() else 0;
        const n_msgs  = if (self.cache_mensagens) |c| c.contagem() else 0;
        std.log.info(
            "[Telemetria] Uptime: {d}s | RSS: {d}KB | cache_ia: {d} | cache_msgs: {d}",
            .{ uptime, rss_kb, n_ia, n_msgs },
        );
    }

    fn limparCaches(self: *Telemetria) void {
        if (self.cache_ia)        |c| c.limparExpirados();
        if (self.cache_mensagens) |c| c.limpar();
    }
};

// ---------------------------------------------------------------------------
// Lê uso de memória RSS via /proc/self/status (Linux).
// Retorna valor em KB ou null se indisponível.
// ---------------------------------------------------------------------------

fn lerRssKb() ?usize {
    var buf: [2048]u8 = undefined;
    const f = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return null;
    defer f.close();
    const n = f.readAll(&buf) catch return null;
    var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            const rest = std.mem.trim(u8, line["VmRSS:".len..], " \t");
            const end  = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            return std.fmt.parseInt(usize, rest[0..end], 10) catch null;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lerRssKb: retorna valor ou null (não trava)" {
    // Apenas valida que não trava — pode retornar null fora do Linux
    _ = lerRssKb();
    try testing.expect(true);
}

test "Telemetria: init com nulls não trava" {
    var t = Telemetria.init(.{}, null, null);
    t.registrarStats();
    t.limparCaches();
    try testing.expect(true);
}
