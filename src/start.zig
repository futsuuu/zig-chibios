const root = @import("root");
const exception = @import("exception.zig");

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
    exception.initHandler();
    exception.saveCurrentKernelStack(stack_top);
    @call(.always_inline, root.main, .{});
    while (true) asm volatile ("wfi");
}
