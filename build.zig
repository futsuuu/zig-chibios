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

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = target,
        .optimize = optimize,
        .no_builtin = true,
        .strip = false,
        .stack_protector = false,
    });
    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = kernel_mod,
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
        "-no-reboot",
        "-action",
        "panic=exit-failure",
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
    for ([_]struct {
        name: []const u8,
        optimize: std.builtin.OptimizeMode,
    }{
        .{
            .name = "test-debug",
            .optimize = .Debug,
        },
        .{
            .name = "test-release",
            .optimize = .ReleaseSafe,
        },
        .{
            .name = "test-unsafe",
            .optimize = .ReleaseSmall,
        },
    }) |opts| {
        const kernel_tests_mod = b.createModule(.{
            .root_source_file = b.path("src/kernel.zig"),
            .target = target,
            .optimize = opts.optimize,
            .no_builtin = true,
            .strip = false,
            .stack_protector = false,
        });
        const kernel_tests = b.addTest(.{
            .name = opts.name,
            .root_module = kernel_tests_mod,
            .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
        });
        kernel_tests_mod.addImport("kernel", kernel_tests_mod); // needed for custom test runner
        kernel_tests.setLinkerScript(b.path("src/kernel.ld"));
        kernel_tests.setExecCmd(&.{
            qemu,
            "-machine",
            "virt",
            "-bios",
            "default",
            "-nographic",
            "-serial",
            "mon:stdio",
            "-no-reboot",
            "-action",
            "panic=exit-failure",
            "-d",
            "unimp,guest_errors,int,cpu_reset",
            "-D",
            "qemu.log",
            "-kernel",
            null,
        });
        const run_kernel_tests = b.addRunArtifact(kernel_tests);
        test_step.dependOn(&run_kernel_tests.step);
    }
}
