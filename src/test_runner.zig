const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.test_runner);

const kernel = @import("kernel");

pub const panic = kernel.panic;
pub const std_options = kernel.std_options;

pub fn main() void {
    kernel.sbi.console.putChar('\n');

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

    kernel.sbi.console.putChar('\n');
    if (has_err) {
        VirtTest.mem.* = .{ .status = .fail, .code = 1 };
        while (true) asm volatile ("wfi");
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

    const mem: *volatile VirtTest = @ptrFromInt(0x100000);
};
