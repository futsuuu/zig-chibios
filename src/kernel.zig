const std = @import("std");
const log = std.log.scoped(.kernel);

pub const panic = blk: {
    break :blk std.debug.FullPanic(struct {
        fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
            @branchHint(.cold);
            _ = first_trace_addr;
            log.err("PANIC: {s}", .{msg});
            while (true) asm volatile ("wfi");
        }
    }.panic);
};

pub const std_options: std.Options = blk: {
    const funcs = struct {
        fn logFn(
            comptime level: std.log.Level,
            comptime scope: @Type(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            const level_text = comptime level.asText();
            const scope_text = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
            var writer = sbi.console.writer();
            writer.print(level_text ++ scope_text ++ format ++ "\n", args) catch {};
        }
    };
    break :blk .{
        .logFn = funcs.logFn,
    };
};

// idk why, but `extern` keyword doesn't work properly
const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern([*]u8, .{ .name = "__stack_top" });

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ mv sp, %[stack_top]
        \\ j kernelMain
        :
        : [stack_top] "r" (stack_top),
    );
}

export fn kernelMain() noreturn {
    @memset(bss[0 .. @intFromPtr(bss_end) - @intFromPtr(bss)], 0);

    sbi.console.putChar('\n');
    log.info("Hello {s}!", .{"World"});

    writeCsr(.stvec, @intFromPtr(&kernelEntry));
    asm volatile ("unimp");

    @panic("unreachable");
}

fn kernelEntry() align(4) callconv(.naked) noreturn {
    asm volatile (
        \\ csrw sscratch, sp
        \\ addi sp, sp, -4 * 31
        \\ sw ra,  4 * 0(sp)
        \\ sw gp,  4 * 1(sp)
        \\ sw tp,  4 * 2(sp)
        \\ sw t0,  4 * 3(sp)
        \\ sw t1,  4 * 4(sp)
        \\ sw t2,  4 * 5(sp)
        \\ sw t3,  4 * 6(sp)
        \\ sw t4,  4 * 7(sp)
        \\ sw t5,  4 * 8(sp)
        \\ sw t6,  4 * 9(sp)
        \\ sw a0,  4 * 10(sp)
        \\ sw a1,  4 * 11(sp)
        \\ sw a2,  4 * 12(sp)
        \\ sw a3,  4 * 13(sp)
        \\ sw a4,  4 * 14(sp)
        \\ sw a5,  4 * 15(sp)
        \\ sw a6,  4 * 16(sp)
        \\ sw a7,  4 * 17(sp)
        \\ sw s0,  4 * 18(sp)
        \\ sw s1,  4 * 19(sp)
        \\ sw s2,  4 * 20(sp)
        \\ sw s3,  4 * 21(sp)
        \\ sw s4,  4 * 22(sp)
        \\ sw s5,  4 * 23(sp)
        \\ sw s6,  4 * 24(sp)
        \\ sw s7,  4 * 25(sp)
        \\ sw s8,  4 * 26(sp)
        \\ sw s9,  4 * 27(sp)
        \\ sw s10, 4 * 28(sp)
        \\ sw s11, 4 * 29(sp)
        \\
        \\ csrr a0, sscratch
        \\ sw a0,  4 * 30(sp)
        \\
        \\ mv a0, sp
        \\ call handleTrap
        \\
        \\ lw ra,  4 * 0(sp)
        \\ lw gp,  4 * 1(sp)
        \\ lw tp,  4 * 2(sp)
        \\ lw t0,  4 * 3(sp)
        \\ lw t1,  4 * 4(sp)
        \\ lw t2,  4 * 5(sp)
        \\ lw t3,  4 * 6(sp)
        \\ lw t4,  4 * 7(sp)
        \\ lw t5,  4 * 8(sp)
        \\ lw t6,  4 * 9(sp)
        \\ lw a0,  4 * 10(sp)
        \\ lw a1,  4 * 11(sp)
        \\ lw a2,  4 * 12(sp)
        \\ lw a3,  4 * 13(sp)
        \\ lw a4,  4 * 14(sp)
        \\ lw a5,  4 * 15(sp)
        \\ lw a6,  4 * 16(sp)
        \\ lw a7,  4 * 17(sp)
        \\ lw s0,  4 * 18(sp)
        \\ lw s1,  4 * 19(sp)
        \\ lw s2,  4 * 20(sp)
        \\ lw s3,  4 * 21(sp)
        \\ lw s4,  4 * 22(sp)
        \\ lw s5,  4 * 23(sp)
        \\ lw s6,  4 * 24(sp)
        \\ lw s7,  4 * 25(sp)
        \\ lw s8,  4 * 26(sp)
        \\ lw s9,  4 * 27(sp)
        \\ lw s10, 4 * 28(sp)
        \\ lw s11, 4 * 29(sp)
        \\ lw sp,  4 * 30(sp)
        \\ sret
    );
}

export fn handleTrap(frame: *TrapFrame) void {
    _ = frame;
    const scause = readCsr(.scause);
    const stval = readCsr(.stval);
    const user_pc = readCsr(.sepc);
    std.debug.panic("unexpected trap: scause={x}, stval={x}, sepc={x}", .{ scause, stval, user_pc });
}

const TrapFrame = packed struct {
    ra: usize,
    gp: usize,
    tp: usize,
    t0: usize,
    t1: usize,
    t2: usize,
    t3: usize,
    t4: usize,
    t5: usize,
    t6: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
    a7: usize,
    s0: usize,
    s1: usize,
    s2: usize,
    s3: usize,
    s4: usize,
    s5: usize,
    s6: usize,
    s7: usize,
    s8: usize,
    s9: usize,
    s10: usize,
    s11: usize,
    sp: usize,
};

inline fn readCsr(comptime reg: @Type(.enum_literal)) usize {
    return asm volatile ("csrr %[ret], " ++ @tagName(reg)
        : [ret] "=r" (-> usize),
    );
}

inline fn writeCsr(comptime reg: @Type(.enum_literal), value: usize) void {
    asm volatile ("csrw " ++ @tagName(reg) ++ ", %[value]"
        :
        : [value] "r" (value),
    );
}

const sbi = struct {
    const Ret = struct {
        err: usize,
        val: usize,
    };

    fn call(
        arg0: usize,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        fid: usize,
        eid: usize,
    ) Ret {
        var err = arg0;
        var val = arg1;
        asm volatile (
            \\ ecall
            : [r0] "={a0}" (err),
              [r1] "={a1}" (val),
            : [a0] "{a0}" (arg0),
              [a1] "{a1}" (arg1),
              [a2] "{a2}" (arg2),
              [a3] "{a3}" (arg3),
              [a4] "{a4}" (arg4),
              [a5] "{a5}" (arg5),
              [a6] "{a6}" (fid),
              [a7] "{a7}" (eid),
            : .{ .memory = true });
        return .{
            .err = err,
            .val = val,
        };
    }

    const console = struct {
        fn putChar(char: u8) void {
            _ = call(@intCast(char), 0, 0, 0, 0, 0, 0, 1);
        }

        fn writer() std.Io.Writer {
            return .{
                .buffer = &.{},
                .vtable = &.{
                    .drain = drain,
                    .flush = std.Io.Writer.noopFlush,
                },
            };
        }

        fn drain(_: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            var written: usize = 0;
            for (data) |bytes| {
                written += bytes.len;
                for (bytes) |char| putChar(char);
            }
            const last = data[data.len - 1];
            written += last.len * (splat - 1);
            for (0..(splat - 1)) |_| {
                for (last) |char| putChar(char);
            }
            return written;
        }
    };
};
