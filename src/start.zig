const root = @import("root");
const sbi = @import("sbi.zig");

const stack_top = @extern([*]u8, .{ .name = "__stack_top" });

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ mv sp, %[stack_top]
        \\ j kernelMain
        :
        : [stack_top] "r" (stack_top),
    );
}

const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });

export fn kernelMain() callconv(.c) noreturn {
    @memset(bss[0 .. @intFromPtr(bss_end) - @intFromPtr(bss)], 0);
    @call(.always_inline, root.main, .{});
    _ = sbi.system.reset(.shutdown, .no_reason);
    while (true) asm volatile ("wfi");
}
