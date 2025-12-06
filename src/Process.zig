const std = @import("std");

const sv32 = @import("sv32.zig");

const Process = @This();

state: State,
sp: *u8,
page_table: *sv32.PageTable,
stack: [8192]u8 align(@alignOf(usize)),

const State = enum { unused, runnable };

fn new() Process {
    return .{
        .state = .unused,
        .sp = undefined,
        .page_table = undefined,
        .stack = undefined,
    };
}

pub fn reset(self: *Process, pc: usize, pt_allocator: std.mem.Allocator) void {
    self.state = .runnable;
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
        var ptr: [*]usize = @ptrCast(&self.stack);
        break :blk ptr[0 .. self.stack.len * @sizeOf(u8) / @sizeOf(usize)];
    };
    casted_stack[casted_stack.len - 13] = pc;
    for (casted_stack.len - 12..casted_stack.len) |i| {
        casted_stack[i] = 0;
    }
    self.sp = @ptrCast(&casted_stack[casted_stack.len - 13]);

    const kernel_page = @extern([*]usize, .{ .name = "__kernel_page" });
    const kernel_page_end = @extern([*]usize, .{ .name = "__kernel_page_end" });
    const table1: *sv32.PageTable = .init(pt_allocator);
    var paddr = @intFromPtr(kernel_page);
    while (paddr < @intFromPtr(kernel_page_end)) : (paddr += @sizeOf(sv32.PageTable)) {
        table1.mapPage(pt_allocator, paddr, @intCast(paddr), .rwx__);
    }
    self.page_table = table1;
}

fn switchContext(self: *Process, next: *Process) void {
    asm volatile (
        \\ sfence.vma
        \\ csrw satp, %[satp]
        \\ sfence.vma
        \\ csrw sscratch, %[sscratch]
        :
        : [satp] "r" (next.page_table.getSatpValue()),
          [sscratch] "r" (@intFromPtr(&next.stack) + @sizeOf(u8) * next.stack.len),
    );
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
        : [sp_offset] "I" (@offsetOf(Process, "sp")),
        : .{ .memory = true });
}

pub const Scheduler = struct {
    list: std.ArrayList(Process),
    current: *Process,
    idle: *Process,

    pt_allocator: std.mem.Allocator,

    pub fn init(buffer: []Process, pt_allocator: std.mem.Allocator) Scheduler {
        std.debug.assert(1 <= buffer.len);
        var list: std.ArrayList(Process) = .initBuffer(buffer);
        list.appendAssumeCapacity(.new());
        var idle = &list.items[list.items.len - 1];
        idle.reset(0, pt_allocator);
        return .{
            .list = list,
            .idle = idle,
            .current = idle,
            .pt_allocator = pt_allocator,
        };
    }

    pub fn spawn(self: *Scheduler, func: *const fn() void) !*Process {
        const proc = self.getUnused() orelse try self.manage(.new());
        proc.reset(@intFromPtr(func), self.pt_allocator);
        return proc;
    }

    pub fn yield(self: *Scheduler) void {
        const next = self.getNext() orelse return;
        const prev = self.current;
        self.current = next;
        prev.switchContext(next);
    }

    fn getNext(self: *Scheduler) ?*Process {
        const current_idx = self.current - self.list.items.ptr;
        return for (0 .. current_idx) |i| {
            const p = &self.list.items[i];
            if (p.state == .runnable and p != self.idle) break p;
        } else for (current_idx + 1 .. self.list.items.len) |i| {
            const p = &self.list.items[i];
            if (p.state == .runnable and p != self.idle) break p;
        } else null;
    }

    fn getUnused(self: *Scheduler) ?*Process {
        return for (self.list.items) |*p| {
            if (p.state == .unused) break p;
        } else null;
    }

    fn manage(self: *Scheduler, process: Process) !*Process {
        try self.list.appendBounded(process);
        return &self.list.items[self.list.items.len - 1];
    }
};
