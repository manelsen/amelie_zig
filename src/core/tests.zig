// core/tests.zig
// Root de testes do núcleo puro.
// Executado por: zig build test:core

const std = @import("std");

comptime {
    _ = @import("processador.zig");
}
