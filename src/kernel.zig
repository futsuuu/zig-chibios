const std = @import("std");
const log = std.log.scoped(.kernel);

pub const std_options: std.Options = blk: {
    const funcs = struct {
        fn logFn(
            comptime level: std.log.Level,
            comptime scope: @TypeOf(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            const level_text = comptime level.asText();
            const scope_text = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
            var writer = sbi.console.writer();
            writer.print(level_text ++ scope_text ++ format ++ "\n", args) catch {};
        }
    };
    break :blk .{
        .logFn = funcs.logFn,
    };
};

// idk why, but `extern` keyword doesn't work properly
const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern([*]u8, .{ .name = "__stack_top" });

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ mv sp, %[stack_top]
        \\ j kernelMain
        :
        : [stack_top] "r" (stack_top),
    );
}

export fn kernelMain() noreturn {
    const bss_section = bss[0 .. @intFromPtr(bss_end) - @intFromPtr(bss)];
    @memset(bss_section, 0);

    sbi.console.putChar('\n');
    log.info("Hello {s}!", .{"World"});

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

        fn writer() std.Io.Writer {
            return .{
                .buffer = &.{},
                .vtable = &.{
                    .drain = drain,
                    .flush = std.Io.Writer.noopFlush,
                },
            };
        }

        fn drain(_: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            var written: usize = 0;
            for (data) |bytes| {
                written += bytes.len;
                for (bytes) |char| putChar(char);
            }
            const last = data[data.len - 1];
            written += last.len * (splat - 1);
            for (0..(splat - 1)) |_| {
                for (last) |char| putChar(char);
            }
            return written;
        }
    };
};
