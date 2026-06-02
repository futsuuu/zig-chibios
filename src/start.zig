const root = @import("root");
const std = @import("std");

const trap = @import("trap.zig");

const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern(*u8, .{ .name = "__stack_top" });

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ mv sp, %[stack_top]
        \\ j kernelMain
        :
        : [stack_top] "r" (stack_top),
    );
}

/// https://docs.kernel.org/arch/riscv/boot.html
export fn kernelMain(hartid: usize, devicetree_addr: usize) callconv(.c) noreturn {
    @memset(bss[0 .. bss_end - bss], 0);
    trap.initHandler();
    trap.saveCurrentKernelStack(stack_top);
    const res = if (0 < @typeInfo(@TypeOf(root.main)).@"fn".params.len)
        root.main(hartid, devicetree_addr)
    else
        root.main();
    switch (@TypeOf(res)) {
        void => {},
        else => |Result| {
            std.debug.assert(@typeInfo(Result) == .error_union);
            res catch |e| {
                std.debug.panic("root.main() returns {}", .{e});
            };
        },
    }
    while (true) asm volatile ("wfi");
}
