const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.test_runner);

const kernel = @import("kernel");

pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        @branchHint(.cold);
        kernel.printPanicInfo(msg, first_trace_addr);
        VirtTest.write(.{ .status = .fail, .code = 1 });
    }
}.panic);

pub const std_options: std.Options = .{
    .logFn = kernel.std_options.logFn,
    .log_level = .debug,
    .page_size_min = 4 << 10,
    .page_size_max = 4 << 10,
};

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = kernel.os.heap.page_allocator;
    };
};

pub fn main() void {
    kernel.sbi.debug_console.writeByte('\n') catch {};
    kernel.os.heap.initPageAllocator() catch @panic("OOM");

    var has_err = false;
    for (@as([]const std.builtin.TestFn, builtin.test_functions)) |t| {
        if (t.func()) {
            log.info("OK: {s}", .{t.name});
        } else |e| {
            has_err = true;
            log.err("FAIL: {s}", .{t.name});
            log.err("      {}", .{e});
        }
    }

    if (has_err) {
        kernel.sbi.debug_console.writeByte('\n') catch {};
        VirtTest.write(.{ .status = .fail, .code = 1 });
    }
}

/// When using this, the program is needed to be executed with:
/// ```
/// qemu-system-riscvxx -machine virt -action panic=exit-failure
/// ```
const VirtTest = packed struct(u64) {
    status: enum(u16) {
        fail = 0x3333,
        pass = 0x5555,
        reset = 0x7777,
    },
    code: u16,
    _: u32 = 0,

    fn write(self: VirtTest) noreturn {
        asm volatile (
            \\ sfence.vma
            \\ csrw satp, 0
            \\ sfence.vma
        );
        @as(*VirtTest, @ptrFromInt(0x100000)).* = self;
        while (true) asm volatile ("wfi");
    }
};
