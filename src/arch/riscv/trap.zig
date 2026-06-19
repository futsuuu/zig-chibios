const std = @import("std");

const asm_utils = @import("asm_utils.zig");
const csr = @import("csr.zig");

pub fn initHandler() void {
    csr.stvec.write(.{
        .mode = .direct,
        .ptr = kernelEntry,
    });
}

pub fn saveCurrentKernelStack(stack_top: *const anyopaque) void {
    csr.sscratch.write(@intFromPtr(stack_top));
}

fn kernelEntry() align(4) callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint(
            // sp = user_sp;
            // sscratch = kernel_stack_top;
            \\
            // sp = kernel_stack_top;
            // sscratch = user_sp;
            \\ csrrw sp, sscratch, sp
            \\
            // frame: Frame = .{ ... };
            // sp = &frame;
            \\ addi sp, sp, -31 * {[xlenb]}
            \\ {[sX]s} ra,   0 * {[xlenb]}(sp)
            \\ {[sX]s} gp,   1 * {[xlenb]}(sp)
            \\ {[sX]s} tp,   2 * {[xlenb]}(sp)
            \\ {[sX]s} t0,   3 * {[xlenb]}(sp)
            \\ {[sX]s} t1,   4 * {[xlenb]}(sp)
            \\ {[sX]s} t2,   5 * {[xlenb]}(sp)
            \\ {[sX]s} t3,   6 * {[xlenb]}(sp)
            \\ {[sX]s} t4,   7 * {[xlenb]}(sp)
            \\ {[sX]s} t5,   8 * {[xlenb]}(sp)
            \\ {[sX]s} t6,   9 * {[xlenb]}(sp)
            \\ {[sX]s} a0,  10 * {[xlenb]}(sp)
            \\ {[sX]s} a1,  11 * {[xlenb]}(sp)
            \\ {[sX]s} a2,  12 * {[xlenb]}(sp)
            \\ {[sX]s} a3,  13 * {[xlenb]}(sp)
            \\ {[sX]s} a4,  14 * {[xlenb]}(sp)
            \\ {[sX]s} a5,  15 * {[xlenb]}(sp)
            \\ {[sX]s} a6,  16 * {[xlenb]}(sp)
            \\ {[sX]s} a7,  17 * {[xlenb]}(sp)
            \\ {[sX]s} s0,  18 * {[xlenb]}(sp)
            \\ {[sX]s} s1,  19 * {[xlenb]}(sp)
            \\ {[sX]s} s2,  20 * {[xlenb]}(sp)
            \\ {[sX]s} s3,  21 * {[xlenb]}(sp)
            \\ {[sX]s} s4,  22 * {[xlenb]}(sp)
            \\ {[sX]s} s5,  23 * {[xlenb]}(sp)
            \\ {[sX]s} s6,  24 * {[xlenb]}(sp)
            \\ {[sX]s} s7,  25 * {[xlenb]}(sp)
            \\ {[sX]s} s8,  26 * {[xlenb]}(sp)
            \\ {[sX]s} s9,  27 * {[xlenb]}(sp)
            \\ {[sX]s} s10, 28 * {[xlenb]}(sp)
            \\ {[sX]s} s11, 29 * {[xlenb]}(sp)
            \\
            // frame.sp = user_sp;
            \\ csrr a0, sscratch
            \\ {[sX]s} a0,  30 * {[xlenb]}(sp)
            \\
            // sscratch = kernel_stack_top;
            \\ addi a0, sp, 31 * {[xlenb]}
            \\ csrw sscratch, a0
            \\
            // handleTrap(&frame);
            \\ mv a0, sp
            \\ call handleTrap
            \\
            \\ {[lX]s} ra,   0 * {[xlenb]}(sp)
            \\ {[lX]s} gp,   1 * {[xlenb]}(sp)
            \\ {[lX]s} tp,   2 * {[xlenb]}(sp)
            \\ {[lX]s} t0,   3 * {[xlenb]}(sp)
            \\ {[lX]s} t1,   4 * {[xlenb]}(sp)
            \\ {[lX]s} t2,   5 * {[xlenb]}(sp)
            \\ {[lX]s} t3,   6 * {[xlenb]}(sp)
            \\ {[lX]s} t4,   7 * {[xlenb]}(sp)
            \\ {[lX]s} t5,   8 * {[xlenb]}(sp)
            \\ {[lX]s} t6,   9 * {[xlenb]}(sp)
            \\ {[lX]s} a0,  10 * {[xlenb]}(sp)
            \\ {[lX]s} a1,  11 * {[xlenb]}(sp)
            \\ {[lX]s} a2,  12 * {[xlenb]}(sp)
            \\ {[lX]s} a3,  13 * {[xlenb]}(sp)
            \\ {[lX]s} a4,  14 * {[xlenb]}(sp)
            \\ {[lX]s} a5,  15 * {[xlenb]}(sp)
            \\ {[lX]s} a6,  16 * {[xlenb]}(sp)
            \\ {[lX]s} a7,  17 * {[xlenb]}(sp)
            \\ {[lX]s} s0,  18 * {[xlenb]}(sp)
            \\ {[lX]s} s1,  19 * {[xlenb]}(sp)
            \\ {[lX]s} s2,  20 * {[xlenb]}(sp)
            \\ {[lX]s} s3,  21 * {[xlenb]}(sp)
            \\ {[lX]s} s4,  22 * {[xlenb]}(sp)
            \\ {[lX]s} s5,  23 * {[xlenb]}(sp)
            \\ {[lX]s} s6,  24 * {[xlenb]}(sp)
            \\ {[lX]s} s7,  25 * {[xlenb]}(sp)
            \\ {[lX]s} s8,  26 * {[xlenb]}(sp)
            \\ {[lX]s} s9,  27 * {[xlenb]}(sp)
            \\ {[lX]s} s10, 28 * {[xlenb]}(sp)
            \\ {[lX]s} s11, 29 * {[xlenb]}(sp)
            \\ {[lX]s} sp,  30 * {[xlenb]}(sp)
            \\ sret
        , .{
            .lX = asm_utils.load_xlen,
            .sX = asm_utils.store_xlen,
            .xlenb = asm_utils.xlenb,
        }));
}

export fn handleTrap(frame: *Frame) void {
    _ = frame;
    const scause = csr.scause.read();
    switch (scause) {
        .interrupt => |interrupt| switch (interrupt) {
            else => std.debug.panic("unexpected interrupt {f}: stval = 0x{X}, sepc = 0x{X}", .{
                interrupt,
                csr.stval.read(),
                csr.sepc.read(),
            }),
        },
        .exception => |exception| switch (exception) {
            else => std.debug.panic("unexpected exception {f}: stval = 0x{X}, sepc = 0x{X}", .{
                exception,
                csr.stval.read(),
                csr.sepc.read(),
            }),
        },
    }
}

const Frame = extern struct {
    ra: usize,
    gp: usize,
    tp: usize,
    t: [7]usize,
    a: [8]usize,
    s: [12]usize,
    sp: usize,
};
