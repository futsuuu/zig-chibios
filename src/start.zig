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

export fn kernelMain() callconv(.c) noreturn {
    @memset(bss[0 .. bss_end - bss], 0);
    trap.initHandler();
    trap.saveCurrentKernelStack(stack_top);
    switch (@typeInfo(@TypeOf(root.main)).@"fn".return_type.?) {
        void, noreturn => {
            root.main();
        },
        else => |ReturnType| {
            std.debug.assert(@typeInfo(ReturnType) == .error_union);
            root.main() catch |e| {
                std.debug.panic("root.main() returns {}", .{e});
            };
        },
    }
    while (true) asm volatile ("wfi");
}
