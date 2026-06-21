const std = @import("std");

const arch = @import("../root.zig");
const asm_utils = @import("asm_utils.zig");

const Context = @This();

stack_ptr: *align(arch.stack_unit_size) const Registers,

const Registers = extern struct {
    ra: usize,
    s: [12]usize = @splat(0),
    _: [3]usize = @splat(0),

    const stack_unit_count = @divExact(@sizeOf(Registers), arch.stack_unit_size);
};

pub fn init(stack: []align(arch.stack_unit_size) [arch.stack_unit_size]u8, return_address: usize) Context {
    const reg: *align(arch.stack_unit_size) Registers = @ptrCast(&stack[stack.len - Registers.stack_unit_count]);
    reg.* = .{
        .ra = return_address,
    };
    return .{
        .stack_ptr = reg,
    };
}

test init {
    var stack: [64][arch.stack_unit_size]u8 align(arch.stack_unit_size) = undefined;
    _ = Context.init(&stack, 7);
    const s = @as([*]usize, @ptrCast(&stack))[0 .. @sizeOf(@TypeOf(stack)) / @sizeOf(usize)];
    try std.testing.expectEqual(7, s[s.len - 16]);
    try std.testing.expectEqual(0, s[s.len - 15]);
    try std.testing.expectEqual(0, s[s.len - 4]);
    try std.testing.expectEqual(0, s[s.len - 1]);
}

pub fn overwrite(self: Context) void {
    asm volatile (std.fmt.comptimePrint(
            \\ {[lX]s} sp, (%[next])
            \\ {[lX]s} ra,   0 * {[xlenb]}(sp)
            \\ {[lX]s} s0,   1 * {[xlenb]}(sp)
            \\ {[lX]s} s1,   2 * {[xlenb]}(sp)
            \\ {[lX]s} s2,   3 * {[xlenb]}(sp)
            \\ {[lX]s} s3,   4 * {[xlenb]}(sp)
            \\ {[lX]s} s4,   5 * {[xlenb]}(sp)
            \\ {[lX]s} s5,   6 * {[xlenb]}(sp)
            \\ {[lX]s} s6,   7 * {[xlenb]}(sp)
            \\ {[lX]s} s7,   8 * {[xlenb]}(sp)
            \\ {[lX]s} s8,   9 * {[xlenb]}(sp)
            \\ {[lX]s} s9,  10 * {[xlenb]}(sp)
            \\ {[lX]s} s10, 11 * {[xlenb]}(sp)
            \\ {[lX]s} s11, 12 * {[xlenb]}(sp)
            \\ addi sp, sp, {[sizeof_registers]}
            \\ ret
        , .{
            .lX = asm_utils.load_xlen,
            .xlenb = asm_utils.xlenb,
            .sizeof_registers = @sizeOf(Registers),
        })
        :
        : [next] "r" (&self.stack_ptr),
        : .{ .memory = true });
}

// FIXME: I don't know why this doesn't work when inlined :(
pub noinline fn switchTo(self: *Context, next: Context) void {
    asm volatile ("jalr ra, %[func]"
        :
        : [prev] "{a0}" (&self.stack_ptr),
          [next] "{a1}" (&next.stack_ptr),
          [func] "r" (&swtch),
        : .{ .x1 = true }); // ra
}

fn swtch(
    // prev: *sp,
    // next: *const sp,
) callconv(.naked) noreturn {
    asm volatile (std.fmt.comptimePrint(
            \\ addi sp, sp, -{[sizeof_registers]}
            \\ {[sX]s} ra,   0 * {[xlenb]}(sp)
            \\ {[sX]s} s0,   1 * {[xlenb]}(sp)
            \\ {[sX]s} s1,   2 * {[xlenb]}(sp)
            \\ {[sX]s} s2,   3 * {[xlenb]}(sp)
            \\ {[sX]s} s3,   4 * {[xlenb]}(sp)
            \\ {[sX]s} s4,   5 * {[xlenb]}(sp)
            \\ {[sX]s} s5,   6 * {[xlenb]}(sp)
            \\ {[sX]s} s6,   7 * {[xlenb]}(sp)
            \\ {[sX]s} s7,   8 * {[xlenb]}(sp)
            \\ {[sX]s} s8,   9 * {[xlenb]}(sp)
            \\ {[sX]s} s9,  10 * {[xlenb]}(sp)
            \\ {[sX]s} s10, 11 * {[xlenb]}(sp)
            \\ {[sX]s} s11, 12 * {[xlenb]}(sp)
            // prev = sp
            \\ {[sX]s} sp, (a0)
            // sp = next
            \\ {[lX]s} sp, (a1)
            \\ {[lX]s} ra,   0 * {[xlenb]}(sp)
            \\ {[lX]s} s0,   1 * {[xlenb]}(sp)
            \\ {[lX]s} s1,   2 * {[xlenb]}(sp)
            \\ {[lX]s} s2,   3 * {[xlenb]}(sp)
            \\ {[lX]s} s3,   4 * {[xlenb]}(sp)
            \\ {[lX]s} s4,   5 * {[xlenb]}(sp)
            \\ {[lX]s} s5,   6 * {[xlenb]}(sp)
            \\ {[lX]s} s6,   7 * {[xlenb]}(sp)
            \\ {[lX]s} s7,   8 * {[xlenb]}(sp)
            \\ {[lX]s} s8,   9 * {[xlenb]}(sp)
            \\ {[lX]s} s9,  10 * {[xlenb]}(sp)
            \\ {[lX]s} s10, 11 * {[xlenb]}(sp)
            \\ {[lX]s} s11, 12 * {[xlenb]}(sp)
            \\ addi sp, sp, {[sizeof_registers]}
            \\ ret
        , .{
            .lX = asm_utils.load_xlen,
            .sX = asm_utils.store_xlen,
            .xlenb = asm_utils.xlenb,
            .sizeof_registers = @sizeOf(Registers),
        }) ::: .{ .memory = true });
}

test "switch context multiple times" {
    const mod = struct {
        var cx_a: Context = undefined;
        var cx_b: Context = undefined;
        fn entryA() void {
            for (0..45678) |_| {
                cx_a.switchTo(cx_b);
            }
        }
        var counter: usize = 0;
        fn entryB() void {
            while (true) {
                counter += 1;
                cx_b.switchTo(cx_a);
            }
        }
    };
    var stack_a: [64][arch.stack_unit_size]u8 align(arch.stack_unit_size) = undefined;
    mod.cx_a = .init(&stack_a, @intFromPtr(&mod.entryA));
    var stack_b: [64][arch.stack_unit_size]u8 align(arch.stack_unit_size) = undefined;
    mod.cx_b = .init(&stack_b, @intFromPtr(&mod.entryB));
    @call(.never_inline, mod.entryA, .{});
    try std.testing.expectEqual(mod.counter, 45678);
}
