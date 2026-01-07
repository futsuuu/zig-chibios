const std = @import("std");
const Allocator = std.mem.Allocator;

const sv32 = @import("sv32.zig");
const trap = @import("trap.zig");

const Process = @This();

state: State,
page_table: *sv32.PageTable,
stack: [8192]u8 align(@alignOf(usize)),
context: Context,

const State = enum { unused, runnable };

fn new() Process {
    return .{
        .state = .unused,
        .page_table = undefined,
        .stack = undefined,
        .context = undefined,
    };
}

pub fn reset(self: *Process, allocator: Allocator, pc: usize) Allocator.Error!void {
    self.state = .runnable;
    self.context = .init(&self.stack, pc);
    const kernel_page = @extern([*]usize, .{ .name = "__kernel_page" });
    const kernel_page_end = @extern([*]usize, .{ .name = "__kernel_page_end" });
    const table1: *sv32.PageTable = try .init(allocator);
    var paddr = @intFromPtr(kernel_page);
    while (paddr < @intFromPtr(kernel_page_end)) : (paddr += @sizeOf(sv32.PageTable)) {
        try table1.mapPage(allocator, paddr, @intCast(paddr), .rwx__);
    }
    self.page_table = table1;
}

fn switchContext(self: *Process, next: *Process) void {
    next.page_table.activate();
    trap.saveCurrentKernelStack(next.stack[next.stack.len..].ptr);
    self.context.switchTo(&next.context);
}

pub const Scheduler = struct {
    list: std.ArrayList(Process),
    current: *Process,
    idle: *Process,

    allocator: std.mem.Allocator,

    pub fn init(allocator: Allocator, buffer: []Process) Allocator.Error!Scheduler {
        std.debug.assert(1 <= buffer.len);
        var list: std.ArrayList(Process) = .initBuffer(buffer);
        list.appendAssumeCapacity(.new());
        var idle = &list.items[list.items.len - 1];
        try idle.reset(allocator, 0);
        return .{
            .list = list,
            .idle = idle,
            .current = idle,
            .allocator = allocator,
        };
    }

    pub fn spawn(self: *Scheduler, func: *const fn () void) !*Process {
        const proc = self.getUnused() orelse try self.manage(.new());
        try proc.reset(self.allocator, @intFromPtr(func));
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
        return for (0..current_idx) |i| {
            const p = &self.list.items[i];
            if (p.state == .runnable and p != self.idle) break p;
        } else for (current_idx + 1..self.list.items.len) |i| {
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

pub const Context = struct {
    stack_pointer: *Format,

    const Format = extern struct {
        ra: usize,
        s0: usize = 0,
        s1: usize = 0,
        s2: usize = 0,
        s3: usize = 0,
        s4: usize = 0,
        s5: usize = 0,
        s6: usize = 0,
        s7: usize = 0,
        s8: usize = 0,
        s9: usize = 0,
        s10: usize = 0,
        s11: usize = 0,
    };

    fn init(stack: []align(@alignOf(usize)) u8, return_address: usize) Context {
        var stack_usize = @as([*]usize, @ptrCast(stack))[0 .. stack.len / @sizeOf(usize)];
        const format: *Format = @ptrCast(&stack_usize[stack_usize.len - @sizeOf(Format) / @sizeOf(usize)]);
        format.* = .{
            .ra = return_address,
        };
        return .{
            .stack_pointer = format,
        };
    }
    test init {
        var stack: [1024]u8 align(@alignOf(usize)) = undefined;
        _ = init(&stack, 7);
        const s = @as([*]usize, @ptrCast(&stack))[0 .. stack.len / @sizeOf(usize)];
        try std.testing.expect(7 == s[s.len - 13]);
        try std.testing.expect(0 == s[s.len - 12]);
        try std.testing.expect(0 == s[s.len - 2]);
        try std.testing.expect(0 == s[s.len - 1]);
    }

    // FIXME: I don't know why this doesn't work when inlined :(
    noinline fn switchTo(self: *Context, next: *Context) void {
        asm volatile ("jalr ra, %[func]"
            :
            : [prev] "{a0}" (&self.stack_pointer),
              [next] "{a1}" (&next.stack_pointer),
              [func] "r" (&swtch),
            : .{ .x1 = true }); // ra
    }
    fn swtch(
        // prev: *sp,
        // next: *sp,
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
                    cx_a.switchTo(&cx_b);
                }
            }
            var counter: usize = 0;
            fn entryB() void {
                while (true) {
                    counter += 1;
                    cx_b.switchTo(&cx_a);
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
};
