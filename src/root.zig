const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.kernel);

const arch = @import("arch");
const shared = @import("shared");

pub const Process = @import("Process.zig");

pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        @branchHint(.cold);
        printPanicInfo(msg, first_trace_addr);
        while (true) asm volatile ("wfi");
    }
}.panic);

pub const std_options: std.Options = .{
    .page_size_min = arch.riscv.sv32.page_size,
    .page_size_max = arch.riscv.sv32.page_size,
};

pub const std_options_debug_io = shared.minimum_debug_io.init(arch.riscv.sbi.debug_console.writer());

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
