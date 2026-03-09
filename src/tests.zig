// src/tests.zig
// Root único de testes — nível src/ permite imports cruzados entre subdiretórios.
// Execute: zig build test

comptime {
    // Domínio puro (GREEN esperado)
    _ = @import("dominio/config.zig");
    _ = @import("dominio/comando.zig");
    _ = @import("dominio/mensagem.zig");
    _ = @import("dominio/acao.zig");

    // Núcleo puro
    _ = @import("core/processador.zig");

    // Infra
    _ = @import("infra/http.zig");
    _ = @import("infra/resilience.zig");
    _ = @import("infra/gemini.zig");
    _ = @import("infra/openrouter.zig");
    _ = @import("infra/sqlite.zig");
    _ = @import("infra/cache_ia.zig");
    _ = @import("infra/cache_mensagens.zig");
    _ = @import("infra/telemetria.zig");
    _ = @import("infra/google_file_api.zig");

    // Shell
    _ = @import("shell/handler.zig");
    _ = @import("shell/fila_midia.zig");
}
