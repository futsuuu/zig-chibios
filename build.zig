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

    const run_step = b.step("run", "Run the kernel with QEMU");
    const test_step = b.step("test", "Run tests");

    const shared_mod = shared: {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/shared/root.zig"),
            .target = b.graph.host,
        });
        const shared_tests = b.addTest(.{
            .name = "test-shared",
            .root_module = mod,
        });
        test_step.dependOn(&b.addRunArtifact(shared_tests).step);
        break :shared mod;
    };

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .no_builtin = true,
        .strip = false,
        .stack_protector = false,
        .imports = &.{
            .{ .name = "shared", .module = shared_mod },
        },
    });

    const kernel_elf = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .no_builtin = true,
            .strip = false,
            .stack_protector = false,
            .imports = &.{
                .{ .name = "kernel", .module = kernel_mod },
                .{ .name = "shared", .module = shared_mod },
            },
        }),
    });
    kernel_elf.setLinkerScript(b.path("src/kernel.ld"));
    b.installArtifact(kernel_elf);

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
    });
    run_cmd.addArgs(&.{
        "-global", "virtio-mmio.force-legacy=false",
        "-drive",  "id=drive0,file=./disk/lorem.txt,format=raw,if=none",
        "-device", "virtio-blk-device,drive=drive0,packed=true",
        "-netdev", "user,id=net0",
        "-device", "virtio-net-device,netdev=net0,packed=true",
    });
    run_cmd.addArg("-kernel");
    run_cmd.addArtifactArg(kernel_elf);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

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
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = opts.optimize,
            .no_builtin = true,
            .strip = false,
            .stack_protector = false,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
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
