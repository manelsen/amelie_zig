const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Criar o módulo root com target
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addCSourceFile(.{ .file = b.path("vendor/sqlite3/sqlite3.c") });
    root_module.addIncludePath(b.path("vendor/sqlite3"));

    // TODO: zsqlite será adicionado quando infra/sqlite.zig for implementado.
    // A-Z legada (src/database.zig) depende de zsqlite mas não compila ainda.

    // Executável principal
    const exe = b.addExecutable(.{
        .name = "amelie-zig",
        .root_module = root_module,
    });

    exe.linkLibC();
    b.installArtifact(exe);

    // Comando de execução
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run app");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------------
    // sqlite3 — C amalgamation (vendor/sqlite3/sqlite3.c)
    // -------------------------------------------------------------------------
    const sqlite3_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite3_mod.addCSourceFile(.{ .file = b.path("vendor/sqlite3/sqlite3.c") });
    sqlite3_mod.addIncludePath(b.path("vendor/sqlite3"));

    // -------------------------------------------------------------------------
    // Testes TDD — root em src/ permite imports cruzados entre subdiretórios.
    // -------------------------------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addCSourceFile(.{ .file = b.path("vendor/sqlite3/sqlite3.c") });
    test_mod.addIncludePath(b.path("vendor/sqlite3"));

    const test_all = b.addTest(.{ .root_module = test_mod });

    const run_tests = b.addRunArtifact(test_all);
    const step_test = b.step("test", "Todos os testes");
    step_test.dependOn(&run_tests.step);
}
