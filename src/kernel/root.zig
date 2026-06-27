const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.kernel);

const arch = @import("arch");
const shared = @import("shared");

pub const Process = @import("Process.zig");

pub const debug = struct {
    pub const SelfInfo = @import("DummySelfInfo.zig");

    pub fn printLineFromFile(io: std.Io, w: *std.Io.Writer, src: std.debug.SourceLocation) !void {
        _ = io;
        try w.print("{any}", .{src});
    }
};

pub fn printPanicInfo(msg: []const u8, first_trace_addr: ?usize) void {
    @branchHint(.cold);
    log.err("PANIC at 0x{x}: {s}", .{ first_trace_addr orelse 0, msg });
    std.debug.dumpCurrentStackTrace(.{
        .first_address = first_trace_addr,
        .allow_unsafe_unwind = true,
    });
}

pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        @branchHint(.cold);
        printPanicInfo(msg, first_trace_addr);
        while (true) asm volatile ("wfi");
    }
}.panic);

pub const std_options: std.Options = .{
    .page_size_min = arch.mmu.page_size,
    .page_size_max = arch.mmu.page_size,
};

pub const std_options_debug_io = shared.minimum_debug_io.init(arch.riscv.sbi.debug_console.writer());

comptime {
    std.testing.refAllDecls(@This());
}
