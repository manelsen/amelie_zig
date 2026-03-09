// infra/resilience.zig
// Decorator genérico de resiliência: retry + circuit breaker.
//
// Uso:
//   const GeminiResistente = Resiliente(GeminiAdapter);
//   var cliente = GeminiResistente.init(gemini, config, allocator);
//   const resp = try cliente.gerarTexto(prompt, system_prompt);
//
// T deve implementar a "interface" IA por duck typing:
//   gerarTexto(self: *T, prompt, system_prompt, alloc) ![]const u8
//   processarMidia(self: *T, dados, mimetype, prompt, alloc) ![]const u8
//
// Resiliente(T) não sabe qual provider é T — só sabe que T falha às vezes.

const std = @import("std");

// ---------------------------------------------------------------------------
// Configuração
// ---------------------------------------------------------------------------

pub const ResilienceConfig = struct {
    max_retries:        u8    = 5,
    backoff_inicial_ms: u64   = 1_000,   // 1s, dobra a cada tentativa
    timeout_cb_ms:      u64   = 60_000,  // 60s aberto antes de meio-aberto
    limiar_falhas:      u8    = 5,       // falhas para abrir o circuito
    max_concorrente:    usize = 20,      // limite de chamadas simultâneas (rate limiting)
};

// ---------------------------------------------------------------------------
// Semaphore — limita chamadas concorrentes (rate limiting)
// ---------------------------------------------------------------------------

pub const Semaphore = struct {
    mutex: std.Thread.Mutex     = .{},
    cond:  std.Thread.Condition = .{},
    atual: usize                = 0,
    max:   usize,

    /// Bloqueia até haver slot disponível e então ocupa um.
    pub fn acquire(self: *Semaphore) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.atual >= self.max) {
            self.cond.wait(&self.mutex);
        }
        self.atual += 1;
    }

    /// Libera um slot e notifica uma thread bloqueada.
    pub fn release(self: *Semaphore) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.atual > 0) self.atual -= 1;
        self.cond.signal();
    }

    pub fn ocupados(self: *Semaphore) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.atual;
    }
};

// ---------------------------------------------------------------------------
// Circuit Breaker
// ---------------------------------------------------------------------------

pub const EstadoCircuito = enum { fechado, aberto, meio_aberto };

pub const CircuitBreaker = struct {
    config:       ResilienceConfig = .{},
    estado:       EstadoCircuito  = .fechado,
    falhas:       u8              = 0,
    ultimo_falha: i64             = 0,  // timestamp ms
    mutex:        std.Thread.Mutex = .{},

    pub fn aberto(self: *CircuitBreaker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return switch (self.estado) {
            .fechado    => false,
            .meio_aberto => false,  // deixa uma tentativa passar
            .aberto     => {
                // Verifica se o timeout já passou → tenta meio-aberto
                const agora = std.time.milliTimestamp();
                if (agora - self.ultimo_falha >= self.config.timeout_cb_ms) {
                    self.estado = .meio_aberto;
                    return false;
                }
                return true;
            },
        };
    }

    pub fn registrarFalha(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.falhas       += 1;
        self.ultimo_falha  = std.time.milliTimestamp();

        if (self.falhas >= self.config.limiar_falhas) {
            self.estado = .aberto;
        }
    }

    pub fn registrarSucesso(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.falhas = 0;
        self.estado = .fechado;
    }
};

// ---------------------------------------------------------------------------
// Decorator genérico
// ---------------------------------------------------------------------------

/// Envolve qualquer adapter de IA com retry + circuit breaker + rate limiting.
/// T deve ter os métodos: gerarTexto, processarMidia.
pub fn Resiliente(comptime T: type) type {
    return struct {
        inner:  T,
        config: ResilienceConfig,
        cb:     CircuitBreaker,
        sem:    Semaphore,

        const Self = @This();

        pub fn init(inner: T, config: ResilienceConfig) Self {
            return .{
                .inner  = inner,
                .config = config,
                .cb     = .{ .config = config },
                .sem    = .{ .max = config.max_concorrente },
            };
        }

        // --- API delegada com resiliência ---

        pub fn gerarTexto(
            self:          *Self,
            prompt:        []const u8,
            system_prompt: ?[]const u8,
            allocator:     std.mem.Allocator,
        ) ![]const u8 {
            self.sem.acquire();
            defer self.sem.release();
            var t: u8 = 0;
            while (true) {
                if (self.cb.aberto()) return error.CircuitoAberto;
                const r = self.inner.gerarTexto(prompt, system_prompt, allocator);
                if (r) |ok| {
                    self.cb.registrarSucesso();
                    return ok;
                } else |err| {
                    self.cb.registrarFalha();
                    t += 1;
                    if (t >= self.config.max_retries) return err;
                    std.Thread.sleep(backoffNs(self.config.backoff_inicial_ms, t));
                }
            }
        }

        pub fn processarMidia(
            self:      *Self,
            dados:     []const u8,
            mimetype:  []const u8,
            prompt:    ?[]const u8,
            allocator: std.mem.Allocator,
        ) ![]const u8 {
            self.sem.acquire();
            defer self.sem.release();
            var t: u8 = 0;
            while (true) {
                if (self.cb.aberto()) return error.CircuitoAberto;
                const r = self.inner.processarMidia(dados, mimetype, prompt, allocator);
                if (r) |ok| {
                    self.cb.registrarSucesso();
                    return ok;
                } else |err| {
                    self.cb.registrarFalha();
                    t += 1;
                    if (t >= self.config.max_retries) return err;
                    std.Thread.sleep(backoffNs(self.config.backoff_inicial_ms, t));
                }
            }
        }

        // Calcula backoff exponencial em nanosegundos (sem jitter por ora).
        fn backoffNs(base_ms: u64, tentativa: u8) u64 {
            const exp: u6 = @intCast(@min(tentativa - 1, 10)); // cap em 2^10
            return (base_ms * (@as(u64, 1) << exp)) * std.time.ns_per_ms;
        }
    };
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

/// Mock de adapter IA para testes.
/// Falha `falhas_iniciais` vezes, depois retorna `resposta`.
const MockIA = struct {
    falhas_restantes: u8,
    resposta:         []const u8,
    chamadas:         u8 = 0,
    erro_emitido:     anyerror = error.ApiError,

    pub fn gerarTexto(
        self:      *MockIA,
        _prompt:   []const u8,
        _system:   ?[]const u8,
        _alloc:    std.mem.Allocator,
    ) ![]const u8 {
        _ = _prompt; _ = _system; _ = _alloc;
        self.chamadas += 1;
        if (self.falhas_restantes > 0) {
            self.falhas_restantes -= 1;
            return self.erro_emitido;
        }
        return self.resposta;
    }

    pub fn processarMidia(
        self:     *MockIA,
        _dados:   []const u8,
        _mime:    []const u8,
        _prompt:  ?[]const u8,
        _alloc:   std.mem.Allocator,
    ) ![]const u8 {
        _ = _dados; _ = _mime; _ = _prompt; _ = _alloc;
        self.chamadas += 1;
        if (self.falhas_restantes > 0) {
            self.falhas_restantes -= 1;
            return self.erro_emitido;
        }
        return self.resposta;
    }
};

const ResilienteMock = Resiliente(MockIA);

test "retry: sucede após N falhas" {
    const mock = MockIA{ .falhas_restantes = 2, .resposta = "ok" };
    var r = ResilienteMock.init(mock, .{
        .max_retries       = 5,
        .backoff_inicial_ms = 0,  // sem delay nos testes
    });

    const resp = try r.gerarTexto("prompt", null, std.testing.allocator);
    try std.testing.expectEqualStrings("ok", resp);
    try std.testing.expectEqual(@as(u8, 3), r.inner.chamadas); // 2 falhas + 1 sucesso
}

test "retry: esgota tentativas e propaga erro" {
    const mock = MockIA{ .falhas_restantes = 10, .resposta = "nunca" };
    var r = ResilienteMock.init(mock, .{
        .max_retries        = 3,
        .backoff_inicial_ms = 0,
    });

    const result = r.gerarTexto("prompt", null, std.testing.allocator);
    try std.testing.expectError(error.ApiError, result);
    try std.testing.expectEqual(@as(u8, 3), r.inner.chamadas);
}

test "retry: sucesso direto → 1 chamada, sem retry" {
    const mock = MockIA{ .falhas_restantes = 0, .resposta = "imediato" };
    var r = ResilienteMock.init(mock, .{ .backoff_inicial_ms = 0 });

    _ = try r.gerarTexto("prompt", null, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), r.inner.chamadas);
}

test "circuit breaker: abre após limiar de falhas" {
    const mock = MockIA{ .falhas_restantes = 255, .resposta = "" };
    var r = ResilienteMock.init(mock, .{
        .max_retries        = 10,
        .backoff_inicial_ms = 0,
        .limiar_falhas      = 3,
        .timeout_cb_ms      = 999_999, // nunca expira no teste
    });

    // Força 3 falhas individuais via CB direto (sem passar pelo retry completo)
    r.cb.registrarFalha();
    r.cb.registrarFalha();
    r.cb.registrarFalha();

    try std.testing.expectEqual(EstadoCircuito.aberto, r.cb.estado);

    // Próxima chamada deve ser bloqueada pelo CB
    const result = r.gerarTexto("prompt", null, std.testing.allocator);
    try std.testing.expectError(error.CircuitoAberto, result);
    // Mock não foi chamado — CB bloqueou antes
    try std.testing.expectEqual(@as(u8, 0), r.inner.chamadas);
}

test "circuit breaker: sucesso reseta estado" {
    const mock = MockIA{ .falhas_restantes = 0, .resposta = "ok" };
    var r = ResilienteMock.init(mock, .{ .backoff_inicial_ms = 0 });

    r.cb.registrarFalha();
    r.cb.registrarFalha();
    try std.testing.expectEqual(@as(u8, 2), r.cb.falhas);

    _ = try r.gerarTexto("x", null, std.testing.allocator);

    try std.testing.expectEqual(EstadoCircuito.fechado, r.cb.estado);
    try std.testing.expectEqual(@as(u8, 0), r.cb.falhas);
}

test "circuit breaker: meio-aberto após timeout" {
    var cb = CircuitBreaker{
        .config = .{ .limiar_falhas = 1, .timeout_cb_ms = 0 }, // timeout = 0ms
    };
    cb.registrarFalha(); // abre
    try std.testing.expectEqual(EstadoCircuito.aberto, cb.estado);

    // Com timeout=0, cb.aberto() deve transitar para meio_aberto imediatamente
    const bloqueado = cb.aberto();
    try std.testing.expectEqual(false, bloqueado);
    try std.testing.expectEqual(EstadoCircuito.meio_aberto, cb.estado);
}

test "backoff: cresce exponencialmente" {
    // backoffNs(1000ms, tentativa) = 1000 * 2^(tentativa-1) ms
    const b1 = Resiliente(MockIA).backoffNs(1_000, 1); // 1s
    const b2 = Resiliente(MockIA).backoffNs(1_000, 2); // 2s
    const b3 = Resiliente(MockIA).backoffNs(1_000, 3); // 4s
    try std.testing.expectEqual(b1 * 2, b2);
    try std.testing.expectEqual(b2 * 2, b3);
}

test "semaphore: não bloqueia abaixo do limite" {
    var sem = Semaphore{ .max = 3 };
    sem.acquire();
    sem.acquire();
    try std.testing.expectEqual(@as(usize, 2), sem.ocupados());
    sem.release();
    sem.release();
    try std.testing.expectEqual(@as(usize, 0), sem.ocupados());
}

test "semaphore: limite respeitado (acquire/release par)" {
    var sem = Semaphore{ .max = 1 };
    sem.acquire();
    try std.testing.expectEqual(@as(usize, 1), sem.ocupados());
    sem.release();
    try std.testing.expectEqual(@as(usize, 0), sem.ocupados());
    // Segunda aquisição deve funcionar após release
    sem.acquire();
    try std.testing.expectEqual(@as(usize, 1), sem.ocupados());
    sem.release();
}

test "Resiliente: semaphore inicializado com max_concorrente" {
    const mock = MockIA{ .falhas_restantes = 0, .resposta = "ok" };
    const r = ResilienteMock.init(mock, .{ .backoff_inicial_ms = 0, .max_concorrente = 5 });
    try std.testing.expectEqual(@as(usize, 5), r.sem.max);
}

test "processarMidia: retry funciona igual a gerarTexto" {
    const mock = MockIA{ .falhas_restantes = 1, .resposta = "desc" };
    var r = ResilienteMock.init(mock, .{ .backoff_inicial_ms = 0 });

    const resp = try r.processarMidia("bytes", "image/jpeg", null, std.testing.allocator);
    try std.testing.expectEqualStrings("desc", resp);
    try std.testing.expectEqual(@as(u8, 2), r.inner.chamadas);
}
