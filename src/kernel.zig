const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.kernel);

pub const Process = @import("Process.zig");
pub const buddy_allocator = @import("buddy_allocator.zig");
pub const sbi = @import("sbi.zig");
pub const sv32 = @import("sv32.zig");
pub const trap = @import("trap.zig");
pub const virtio = @import("virtio.zig");

comptime {
    _ = @import("start.zig");
}

pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        @branchHint(.cold);
        printPanicInfo(msg, first_trace_addr);
        while (true) asm volatile ("wfi");
    }
}.panic);

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
            var writer = sbi.debug_console.writer();
            writer.print(level_text ++ scope_text ++ format ++ "\n", args) catch {};
        }
    };
    break :blk .{
        .logFn = funcs.logFn,
        .page_size_min = sv32.page_size,
        .page_size_max = sv32.page_size,
    };
};

pub const os = struct {
    pub const heap = struct {
        const PageAllocator = buddy_allocator.BuddyAllocator(.{});

        pub fn initPageAllocator() std.mem.Allocator.Error!void {
            const free_ram = @extern([*]u8, .{ .name = "__free_ram" });
            const free_ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });
            const buf = free_ram[0 .. free_ram_end - free_ram];
            instance = try .init(buf);
        }

        var instance: PageAllocator = undefined;
        pub const page_allocator: std.mem.Allocator = .{
            .ptr = &instance,
            .vtable = &PageAllocator.vtable,
        };
    };
};

pub fn printPanicInfo(msg: []const u8, first_trace_addr: ?usize) void {
    @branchHint(.cold);
    log.err("PANIC: {s}", .{msg});
    var iter: std.debug.StackIterator = .init(first_trace_addr, null);
    var index: usize = 0;
    while (iter.next()) |addr| : (index += 1) {
        switch (builtin.target.ptrBitWidth()) {
            32 => log.err("{:0>3}: 0x{x:0>8}", .{ index, addr }),
            64 => log.err("{:0>3}: 0x{x:0>16}", .{ index, addr }),
            else => unreachable,
        }
    }
}

var scheduler: Process.Scheduler = undefined;

pub fn main() !void {
    defer log.info("exit", .{});
    sbi.debug_console.writeByte('\n') catch {};

    try os.heap.initPageAllocator();

    var virtq, const register = try virtio.init(std.heap.page_allocator) orelse {
        log.warn("virtio device not found", .{});
        return;
    };

    var buf = std.mem.zeroes([512]u8);
    try virtio.request(&virtq, register, .read, &buf, 0);
    @memcpy(buf[0..].ptr, "hello world!");
    try virtio.request(&virtq, register, .write, &buf, 0);

    scheduler = try .init(std.heap.page_allocator);
    _ = try scheduler.spawn(&procAEntry, 8192);
    _ = try scheduler.spawn(&procBEntry, 8192);
    scheduler.yield();
}

fn delay() void {
    for (0..30000000) |_| {
        asm volatile ("nop");
    }
}

fn procAEntry() void {
    log.debug("starting process A", .{});
    while (true) {
        sbi.debug_console.writeByte('A') catch {};
        scheduler.yield();
        delay();
    }
}

fn procBEntry() void {
    log.debug("starting process B", .{});
    while (true) {
        sbi.debug_console.writeByte('B') catch {};
        scheduler.yield();
        delay();
    }
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
