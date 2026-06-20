const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .riscv64,
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

    const arch_mod = b.createModule(.{
        .root_source_file = b.path("src/arch/root.zig"),
        .target = target,
    });

    // TODO: add tests
    const virtio_mod = b.createModule(.{
        .root_source_file = b.path("src/virtio/root.zig"),
        .imports = &.{
            .{ .name = "arch", .module = arch_mod },
            .{ .name = "shared", .module = shared_mod },
        },
    });

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "arch", .module = arch_mod },
            .{ .name = "shared", .module = shared_mod },
        },
    });

    const kernel_elf = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .medany,
            .no_builtin = true,
            .strip = false,
            .stack_protector = false,
            .imports = &.{
                .{ .name = "arch", .module = arch_mod },
                .{ .name = "kernel", .module = kernel_mod },
                .{ .name = "shared", .module = shared_mod },
                .{ .name = "virtio", .module = virtio_mod },
            },
        }),
    });
    kernel_elf.setLinkerScript(b.path("src/arch/riscv/kernel.ld"));
    b.installArtifact(kernel_elf);

    const qemu = switch (target.result.cpu.arch) {
        .riscv32 => "qemu-system-riscv32",
        .riscv64 => "qemu-system-riscv64",
        else => unreachable,
    };
    const common_qemu_args = [_][]const u8{
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
    };

    const run_cmd = b.addSystemCommand(&.{qemu});
    run_cmd.addArgs(&common_qemu_args);
    run_cmd.addArgs(&.{
        "-global", "virtio-mmio.force-legacy=false",
        "-drive",  "id=drive0,file=fat:./disk,format=raw,media=disk,if=none,readonly=true",
        "-device", "virtio-blk-device,drive=drive0,packed=true",
        "-netdev", "user,id=net0",
        "-device", "virtio-net-device,netdev=net0,packed=true",
    });
    run_cmd.addArg("-kernel");
    run_cmd.addArtifactArg(kernel_elf);
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
        const arch_tests_mod = b.createModule(.{
            .root_source_file = b.path("src/arch/root.zig"),
            .target = target,
            .optimize = opts.optimize,
            .code_model = .medany,
            .no_builtin = true,
            .strip = false,
            .stack_protector = false,
            .imports = &.{
                .{ .name = "shared", .module = shared_mod },
            },
        });
        arch_tests_mod.addImport("arch", arch_tests_mod);
        const arch_tests = b.addTest(.{
            .name = opts.name,
            .root_module = arch_tests_mod,
            .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
        });
        arch_tests.setLinkerScript(b.path("src/arch/riscv/kernel.ld"));
        arch_tests.setExecCmd(&([_]?[]const u8{qemu} ++ common_qemu_args ++ .{ "-kernel", null }));
        const run_arch_tests = b.addRunArtifact(arch_tests);
        test_step.dependOn(&run_arch_tests.step);
    }
}
