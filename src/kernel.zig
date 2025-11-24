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

    for ("\n\nHello World!\n") |c| {
        putchar(c);
    }

    while (true) {
        asm volatile ("wfi");
    }
}

fn putchar(char: u8) void {
    _ = sbiCall(@intCast(char), 0, 0, 0, 0, 0, 0, 1);
}

const SbiRet = struct {
    err: usize,
    val: usize,
};

fn sbiCall(
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    arg5: usize,
    fid: usize,
    eid: usize,
) SbiRet {
    var a0 = arg0;
    var a1 = arg1;
    const a2 = arg2;
    const a3 = arg3;
    const a4 = arg4;
    const a5 = arg5;
    const a6 = fid;
    const a7 = eid;
    asm volatile (
        \\ ecall
        : [r0] "={a0}" (a0),
          [r1] "={a1}" (a1),
        : [a0] "{a0}" (a0),
          [a1] "{a1}" (a1),
          [a2] "{a2}" (a2),
          [a3] "{a3}" (a3),
          [a4] "{a4}" (a4),
          [a5] "{a5}" (a5),
          [a6] "{a6}" (a6),
          [a7] "{a7}" (a7),
        : .{ .memory = true });
    return .{
        .err = a0,
        .val = a1,
    };
}
