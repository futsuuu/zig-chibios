const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.process);

const sv32 = @import("sv32.zig");
const trap = @import("trap.zig");

const Process = @This();

state: State,
page_table: sv32.RootPageTable,
stack: []align(@alignOf(usize)) u8,
context: Context,

const State = enum { unused, runnable };

const uninit: Process = .{
    .state = .unused,
    .page_table = undefined,
    .stack = undefined,
    .context = undefined,
};

fn init(allocator: Allocator, pc: usize, stack_size: usize) Allocator.Error!Process {
    const stack = try allocator.alignedAlloc(u8, .of(usize), stack_size);
    var self: Process = .{
        .state = .runnable,
        .page_table = try .init(allocator),
        .stack = stack,
        .context = .init(stack, pc),
    };
    const kernel_page = @extern(*align(sv32.page_size) u8, .{ .name = "__kernel_page" });
    const kernel_page_end = @extern(*align(sv32.page_size) u8, .{ .name = "__kernel_page_end" });
    var ppn = sv32.PhysAddr.PageNumber.fromPtr(kernel_page);
    while (ppn.num < sv32.PhysAddr.PageNumber.fromPtr(kernel_page_end).num) : (ppn.num += 1) {
        try self.page_table.mapPage(allocator, @intFromPtr(ppn.toPtr()), .init(ppn, .rwx));
    }
    return self;
}

fn deinit(self: *Process, allocator: Allocator, next: ?*const Process) void {
    if (next) |p| {
        p.page_table.activate();
    }
    self.page_table.deinit(allocator);
    allocator.free(self.stack);
    self.* = .uninit;
    if (next) |p| {
        trap.saveCurrentKernelStack(p.stack[p.stack.len..].ptr);
        p.context.overwrite();
    }
}

fn switchContext(self: *Process, next: *const Process) void {
    next.page_table.activate();
    trap.saveCurrentKernelStack(next.stack[next.stack.len..].ptr);
    self.context.switchTo(next.context);
}

pub const Scheduler = struct {
    list: std.ArrayList(Process),
    current: usize,
    idle: usize,

    allocator: std.mem.Allocator,

    pub fn init(allocator: Allocator) Allocator.Error!Scheduler {
        var list: std.ArrayList(Process) = try .initCapacity(allocator, 1);
        list.appendAssumeCapacity(try .init(allocator, 0, 64));
        return .{
            .list = list,
            .idle = 0,
            .current = 0,
            .allocator = allocator,
        };
    }

    pub fn spawn(self: *Scheduler, func: *const fn () void, stack_size: usize) Allocator.Error!*Process {
        const proc = self.getUnused() orelse try self.manage(.uninit);
        proc.* = try .init(self.allocator, @intFromPtr(func), stack_size);
        return proc;
    }

    pub fn yield(self: *Scheduler) void {
        const next = self.getNext() orelse return;
        const prev = &self.list.items[self.current];
        self.current = next - self.list.items.ptr;
        prev.switchContext(next);
    }

    pub fn exit(self: *Scheduler) void {
        self.list.items[self.current].deinit(self.allocator, self.getNext());
    }

    fn getNext(self: *Scheduler) ?*Process {
        return for (self.current + 1..self.list.items.len) |i| {
            const p = &self.list.items[i];
            if (p.state == .runnable and i != self.idle) break p;
        } else for (0..self.current + 1) |i| {
            const p = &self.list.items[i];
            if (p.state == .runnable and i != self.idle) break p;
        } else null;
    }

    fn getUnused(self: *Scheduler) ?*Process {
        return for (self.list.items) |*p| {
            if (p.state == .unused) break p;
        } else null;
    }

    fn manage(self: *Scheduler, process: Process) Allocator.Error!*Process {
        try self.list.append(self.allocator, process);
        return &self.list.items[self.list.items.len - 1];
    }
};

pub const Context = struct {
    stack_ptr: *const Registers,

    const Registers = extern struct {
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
        const stack_usize = @as([*]usize, @ptrCast(stack))[0 .. stack.len / @sizeOf(usize)];
        const reg: *Registers = @ptrCast(&stack_usize[stack_usize.len - @sizeOf(Registers) / @sizeOf(usize)]);
        reg.* = .{
            .ra = return_address,
        };
        return .{
            .stack_ptr = reg,
        };
    }
    test "Context.init" {
        var stack: [1024]u8 align(@alignOf(usize)) = undefined;
        _ = Context.init(&stack, 7);
        const s = @as([*]usize, @ptrCast(&stack))[0 .. stack.len / @sizeOf(usize)];
        try std.testing.expect(7 == s[s.len - 13]);
        try std.testing.expect(0 == s[s.len - 12]);
        try std.testing.expect(0 == s[s.len - 2]);
        try std.testing.expect(0 == s[s.len - 1]);
    }

    fn overwrite(self: Context) void {
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
    noinline fn switchTo(self: *Context, next: Context) void {
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
};
