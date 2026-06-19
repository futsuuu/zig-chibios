const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.process);

const arch = @import("arch");
const sv32 = arch.riscv.sv32;

const Process = @This();

state: State,
page_table: sv32.PageTable(.root),
stack: []align(@alignOf(usize)) u8,
context: arch.Context,

const State = enum { unused, runnable };

const uninit: Process = .{
    .state = .unused,
    .page_table = undefined,
    .stack = undefined,
    .context = undefined,
};

fn init(
    allocator: Allocator,
    pc: usize,
    stack_size: usize,
    kernel_page: []align(sv32.page_size) [sv32.page_size]u8,
) Allocator.Error!Process {
    const stack = try allocator.alignedAlloc(u8, .of(usize), stack_size);
    errdefer allocator.free(stack);
    var self: Process = .{
        .state = .runnable,
        .page_table = try .init(allocator),
        .stack = stack,
        .context = .init(stack, pc),
    };
    for (kernel_page) |*page| {
        var ppn: sv32.PhysAddr.PageNumber = .fromPtr(page);
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
        arch.trap.saveCurrentKernelStack(p.stack[p.stack.len..].ptr);
        p.context.overwrite();
    }
}

fn switchContext(self: *Process, next: *const Process) void {
    next.page_table.activate();
    arch.trap.saveCurrentKernelStack(next.stack[next.stack.len..].ptr);
    self.context.switchTo(next.context);
}

pub const Scheduler = struct {
    list: std.ArrayList(Process),
    current: usize,
    idle: usize,

    allocator: std.mem.Allocator,
    kernel_page: []align(sv32.page_size) [sv32.page_size]u8,

    pub fn init(
        allocator: Allocator,
        kernel_page: []align(sv32.page_size) [sv32.page_size]u8,
    ) Allocator.Error!Scheduler {
        var list: std.ArrayList(Process) = try .initCapacity(allocator, 1);
        list.appendAssumeCapacity(try .init(allocator, 0, 64, kernel_page));
        return .{
            .list = list,
            .idle = 0,
            .current = 0,
            .allocator = allocator,
            .kernel_page = kernel_page,
        };
    }

    pub fn spawn(self: *Scheduler, func: *const fn () void, stack_size: usize) Allocator.Error!*Process {
        const proc = self.getUnused() orelse try self.manage(.uninit);
        proc.* = try .init(self.allocator, @intFromPtr(func), stack_size, self.kernel_page);
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

comptime {
    std.testing.refAllDecls(@This());
}
