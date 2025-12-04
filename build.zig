const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .riscv32,
        .os_tag = .freestanding,
        .ofmt = .elf,
    } });
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
            .no_builtin = true,
            .strip = false,
            .stack_protector = false,
        }),
        .use_lld = true,
    });
    kernel.setLinkerScript(b.path("src/kernel.ld"));
    b.installArtifact(kernel);

    const run_step = b.step("run", "Run the kernel with QEMU");
    const qemu = switch (target.result.cpu.arch) {
        .riscv32 => "qemu-system-riscv32",
        .riscv64 => "qemu-system-riscv64",
        else => unreachable,
    };
    const run_cmd = b.addSystemCommand(&.{
        qemu,
        "-machine",
        "virt",
        "-bios",
        "default",
        "-nographic",
        "-serial",
        "mon:stdio",
        "--no-reboot",
        "-d",
        "unimp,guest_errors,int,cpu_reset",
        "-D",
        "qemu.log",
        "-kernel",
        b.getInstallPath(.bin, kernel.name),
    });
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    const kernel_tests = b.addTest(.{
        .root_module = kernel.root_module,
    });
    const run_kernel_tests = b.addRunArtifact(kernel_tests);
    test_step.dependOn(&run_kernel_tests.step);
}
