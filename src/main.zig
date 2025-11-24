extern var __bss: [*]u8;
extern var __bss_end: [*]u8;
extern var __stack_top: [*]u8;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ mv sp, %[stack_top]
        \\ j kernel_main
        :
        : [stack_top] "r" (__stack_top),
    );
}

export fn kernel_main() callconv(.c) noreturn {
    @memset(__bss[0 .. @intFromPtr(__bss_end) - @intFromPtr(__bss)], 0);
    while (true) {}
}
