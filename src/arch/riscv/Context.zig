const std = @import("std");

const Context = @This();

stack_ptr: *const Registers,

const Registers = extern struct {
    ra: usize,
    s: [12]usize = @splat(0),
};

pub fn init(stack: []align(@alignOf(usize)) u8, return_address: usize) Context {
    const stack_usize = @as([*]usize, @ptrCast(stack))[0 .. stack.len / @sizeOf(usize)];
    const reg: *Registers = @ptrCast(&stack_usize[stack_usize.len - @sizeOf(Registers) / @sizeOf(usize)]);
    reg.* = .{
        .ra = return_address,
    };
    return .{
        .stack_ptr = reg,
    };
}

test init {
    var stack: [1024]u8 align(@alignOf(usize)) = undefined;
    _ = Context.init(&stack, 7);
    const s = @as([*]usize, @ptrCast(&stack))[0 .. stack.len / @sizeOf(usize)];
    try std.testing.expect(7 == s[s.len - 13]);
    try std.testing.expect(0 == s[s.len - 12]);
    try std.testing.expect(0 == s[s.len - 2]);
    try std.testing.expect(0 == s[s.len - 1]);
}

pub fn overwrite(self: Context) void {
    asm volatile (
        \\ lw sp, (%[next])
        \\ lw ra,  0  * 4(sp)
        \\ lw s0,  1  * 4(sp)
        \\ lw s1,  2  * 4(sp)
        \\ lw s2,  3  * 4(sp)
        \\ lw s3,  4  * 4(sp)
        \\ lw s4,  5  * 4(sp)
        \\ lw s5,  6  * 4(sp)
        \\ lw s6,  7  * 4(sp)
        \\ lw s7,  8  * 4(sp)
        \\ lw s8,  9  * 4(sp)
        \\ lw s9,  10 * 4(sp)
        \\ lw s10, 11 * 4(sp)
        \\ lw s11, 12 * 4(sp)
        \\ addi sp, sp, 13 * 4
        \\ ret
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
    asm volatile (
        \\ addi sp, sp, -13 * 4
        \\ sw ra,  0  * 4(sp)
        \\ sw s0,  1  * 4(sp)
        \\ sw s1,  2  * 4(sp)
        \\ sw s2,  3  * 4(sp)
        \\ sw s3,  4  * 4(sp)
        \\ sw s4,  5  * 4(sp)
        \\ sw s5,  6  * 4(sp)
        \\ sw s6,  7  * 4(sp)
        \\ sw s7,  8  * 4(sp)
        \\ sw s8,  9  * 4(sp)
        \\ sw s9,  10 * 4(sp)
        \\ sw s10, 11 * 4(sp)
        \\ sw s11, 12 * 4(sp)
        // prev = sp
        \\ sw sp, (a0)
        // sp = next
        \\ lw sp, (a1)
        \\ lw ra,  0  * 4(sp)
        \\ lw s0,  1  * 4(sp)
        \\ lw s1,  2  * 4(sp)
        \\ lw s2,  3  * 4(sp)
        \\ lw s3,  4  * 4(sp)
        \\ lw s4,  5  * 4(sp)
        \\ lw s5,  6  * 4(sp)
        \\ lw s6,  7  * 4(sp)
        \\ lw s7,  8  * 4(sp)
        \\ lw s8,  9  * 4(sp)
        \\ lw s9,  10 * 4(sp)
        \\ lw s10, 11 * 4(sp)
        \\ lw s11, 12 * 4(sp)
        \\ addi sp, sp, 13 * 4
        \\ ret
        ::: .{ .memory = true });
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
    var stack_a: [1024]u8 align(@alignOf(usize)) = undefined;
    mod.cx_a = .init(&stack_a, @intFromPtr(&mod.entryA));
    var stack_b: [1024]u8 align(@alignOf(usize)) = undefined;
    mod.cx_b = .init(&stack_b, @intFromPtr(&mod.entryB));
    @call(.never_inline, mod.entryA, .{});
    try std.testing.expect(mod.counter == 45678);
}
