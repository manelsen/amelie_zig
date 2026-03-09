// dominio/tests.zig
// Root de testes para todos os módulos de domínio.
// Executado por: zig build test:dominio

const std = @import("std");

comptime {
    _ = @import("config.zig");
    _ = @import("comando.zig");
    _ = @import("mensagem.zig");
    _ = @import("acao.zig");
}
