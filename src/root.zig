const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.kernel);

const shared = @import("shared");

pub const Process = @import("Process.zig");
pub const sbi = @import("sbi.zig");
pub const start = @import("start.zig");
pub const sv32 = @import("sv32.zig");
pub const trap = @import("trap.zig");

comptime {
    _ = start;
}

pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        @branchHint(.cold);
        printPanicInfo(msg, first_trace_addr);
        while (true) asm volatile ("wfi");
    }
}.panic);

pub const std_options: std.Options = .{
    .page_size_min = sv32.page_size,
    .page_size_max = sv32.page_size,
};

pub const std_options_debug_io = @import("debug_io.zig").init(sbi.debug_console.writer());

pub const os = struct {
    pub const heap = struct {
        const PageAllocator = shared.heap.BuddyAllocator(.{});

        pub fn initPageAllocator(free_ram: []u8) std.mem.Allocator.Error!void {
            instance = try .init(free_ram);
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
    _ = first_trace_addr;
    // FIXME: replace StackIterator with captureCurrentStackTrace
    // var iter: std.debug.StackIterator = .init(first_trace_addr, null);
    // var index: usize = 0;
    // while (iter.next()) |addr| : (index += 1) {
    //     switch (builtin.target.ptrBitWidth()) {
    //         32 => log.err("{:0>3}: 0x{x:0>8}", .{ index, addr }),
    //         64 => log.err("{:0>3}: 0x{x:0>16}", .{ index, addr }),
    //         else => unreachable,
    //     }
    // }
}

comptime {
    std.testing.refAllDecls(@This());
}
