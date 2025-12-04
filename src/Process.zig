const std = @import("std");

const sv32 = @import("sv32.zig");

const Self = @This();

state: State,
pid: usize,
sp: *u8,
page_table: *sv32.PageTable,
stack: [8192]u8 align(@alignOf(usize)),

const State = enum { unused, runnable };

var buf: [8]Self = undefined;
var pool: std.ArrayList(Self) = .initBuffer(&buf);

pub fn create(
    pc: usize,
    /// only used for allocating page tables
    pt_allocator: std.mem.Allocator,
) *Self {
    const proc: *Self = blk: for (pool.items) |*p| {
        if (p.state == .unused) break :blk p;
    } else {
        pool.appendBounded(.{
            .state = .unused,
            .pid = pool.items.len,
            .sp = undefined,
            .page_table = undefined,
            .stack = undefined,
        }) catch @panic("no free process slots");
        break :blk &pool.items[pool.items.len - 1];
    };

    proc.state = .runnable;
    //  | ...
    //  |-----> proc.sp
    //  | pc    // -> ra
    //  |-----
    //  | 0     // -> s0
    //  |-----
    //  | 0     // -> s1 .. s10
    //  |-----
    //  | 0     // -> s11
    //  `-----
    const casted_stack = blk: {
        var ptr: [*]usize = @ptrCast(&proc.stack);
        break :blk ptr[0 .. proc.stack.len * @sizeOf(u8) / @sizeOf(usize)];
    };
    casted_stack[casted_stack.len - 13] = pc;
    for (casted_stack.len - 12..casted_stack.len) |i| {
        casted_stack[i] = 0;
    }
    proc.sp = @ptrCast(&casted_stack[casted_stack.len - 13]);

    const page_table: *sv32.PageTable = .init(pt_allocator);
    page_table.mapKernelPage(pt_allocator);
    proc.page_table = page_table;

    return proc;
}

pub fn switchContext(self: *Self, next: *Self) void {
    asm volatile ("jalr %[inner]"
        :
        : [self] "{a0}" (self),
          [next] "{a1}" (next),
          [inner] "r" (&switchContextInner),
        : .{ .x1 = true }); // ra
}

fn switchContextInner(
    // self: *Self,
    // next: *Self,
) callconv(.naked) noreturn {
    asm volatile (
        \\
        // | ...
        // |-----> sp
        // | <- ra
        // |-----
        // | <- s0
        // |-----
        // | <- s1 .. s10
        // |-----
        // | <- s11
        // |-----> prev sp
        // | ...
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

        // self.sp = sp
        \\ sw sp, %[sp_offset](a0)
        // sp = next.sp
        \\ lw sp, %[sp_offset](a1)

        // | ...
        // |-----> next.sp
        // | -> ra
        // |-----
        // | -> s0
        // |-----
        // | -> s1 .. s10
        // |-----
        // | -> s11
        // |-----> sp
        // | ...
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
        : [sp_offset] "I" (@offsetOf(Self, "sp")),
        : .{ .memory = true });
}

var current: *Self = undefined;
var idle: *Self = undefined;

pub fn initGlobal(pt_allocator: std.mem.Allocator) void {
    idle = create(0, pt_allocator);
    current = idle;
}

pub fn yield() void {
    const current_idx = (@intFromPtr(current) - @intFromPtr(&pool.items)) / @sizeOf(Self);
    const next: *Self = for (current_idx + 1..current_idx + pool.items.len) |i| {
        const proc = &pool.items[i % pool.items.len];
        if (proc.state == .runnable and proc != idle) break proc;
    } else {
        return;
    };
    asm volatile (
        \\ sfence.vma
        \\ csrw satp, %[satp]
        \\ sfence.vma
        \\ csrw sscratch, %[sscratch]
        :
        : [satp] "r" (next.page_table.getSatpValue()),
          [sscratch] "r" (@intFromPtr(&next.stack) + @sizeOf(u8) * next.stack.len),
    );
    const prev = current;
    current = next;
    prev.switchContext(next);
}
