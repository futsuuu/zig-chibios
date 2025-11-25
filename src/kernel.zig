extern var __bss: *u8;
extern var __bss_end: *u8;
extern var __stack_top: *u8;

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ mv sp, %[stack_top]
        \\ j kernelMain
        :
        : [stack_top] "r" (__stack_top),
    );
}

export fn kernelMain() noreturn {
    const bss_ptr: [*]u8 = @ptrCast(__bss);
    const bss_section = bss_ptr[0 .. @intFromPtr(__bss_end) - @intFromPtr(__bss)];
    @memset(bss_section, 0);

    for ("\n\nHello World!\n") |c| {
        sbi.console.putChar(c);
    }

    while (true) {
        asm volatile ("wfi");
    }
}

const sbi = struct {
    const Ret = struct {
        err: usize,
        val: usize,
    };

    fn call(
        arg0: usize,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        fid: usize,
        eid: usize,
    ) Ret {
        var err = arg0;
        var val = arg1;
        asm volatile (
            \\ ecall
            : [r0] "={a0}" (err),
              [r1] "={a1}" (val),
            : [a0] "{a0}" (arg0),
              [a1] "{a1}" (arg1),
              [a2] "{a2}" (arg2),
              [a3] "{a3}" (arg3),
              [a4] "{a4}" (arg4),
              [a5] "{a5}" (arg5),
              [a6] "{a6}" (fid),
              [a7] "{a7}" (eid),
            : .{ .memory = true });
        return .{
            .err = err,
            .val = val,
        };
    }

    const console = struct {
        fn putChar(char: u8) void {
            _ = call(@intCast(char), 0, 0, 0, 0, 0, 0, 1);
        }
    };
};
