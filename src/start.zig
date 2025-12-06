const root = @import("root");
const exception = @import("exception.zig");
const sbi = @import("sbi.zig");

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    const stack_top = @extern(*u8, .{ .name = "__stack_top" });
    asm volatile (
        \\ mv sp, %[stack_top]
        \\ j kernelMain
        :
        : [stack_top] "r" (stack_top),
    );
}

export fn kernelMain() callconv(.c) noreturn {
    const bss = @extern([*]u8, .{ .name = "__bss" });
    const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
    @memset(bss[0 .. bss_end - bss], 0);
    exception.initHandler();
    @call(.always_inline, root.main, .{});
    sbi.system.reset(.shutdown, .no_reason) catch {};
    while (true) asm volatile ("wfi");
}
