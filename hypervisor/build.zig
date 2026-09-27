const std = @import("std");

pub fn build(b: *std.Build) void {
    const entry_point = b.path("src/uefi.zig");
    const optimize = b.standardOptimizeOption(.{});

    const aarch64_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .uefi,
    });

    const aarch64 = b.addExecutable(.{ .name = "bootaa64", .root_module = b.createModule(.{
        .root_source_file = entry_point,
        .target = aarch64_target,
        .optimize = optimize,
        .imports = &.{},
    }) });

    const riscv64_target = b.resolveTargetQuery(.{
        .cpu_arch = .riscv64,
        .os_tag = .freestanding,
    });

    const riscv64 = b.addExecutable(.{
        .name = "bootriscv64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/freestanding.zig"),
            .target = riscv64_target,
            .optimize = optimize,
            .imports = &.{},
            .unwind_tables = .none,
        }),
    });

    riscv64.entry = .{ .symbol_name = "efiMain" };
    riscv64.link_emit_relocs = true;
    riscv64.pie = true;
    riscv64.setLinkerScript(b.path("src/arch/riscv64/uefi.lds"));

    const x86_64_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .uefi,
    });

    const x86_64 = b.addExecutable(.{
        .name = "bootx64",
        .root_module = b.createModule(.{
            .root_source_file = entry_point,
            .target = x86_64_target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });

    b.installArtifact(aarch64);
    b.installArtifact(riscv64);
    b.installArtifact(x86_64);
}
