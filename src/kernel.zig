const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.kernel);

pub const Process = @import("Process.zig");
pub const exception = @import("exception.zig");
pub const sbi = @import("sbi.zig");
pub const sv32 = @import("sv32.zig");

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

pub fn main() void {
    sbi.debug_console.writeByte('\n') catch {};

    const free_ram = @extern([*]u8, .{ .name = "__free_ram" });
    const free_ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });
    const buf = free_ram[0 .. free_ram_end - free_ram];
    var fba: std.heap.FixedBufferAllocator = .init(buf);
    const pt_allocator = fba.allocator();

    var proc_buf: [8]Process = undefined;
    scheduler = .init(&proc_buf, pt_allocator);
    _ = scheduler.spawn(&procAEntry) catch unreachable;
    _ = scheduler.spawn(&procBEntry) catch unreachable;
    scheduler.yield();

    log.info("exit", .{});
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
