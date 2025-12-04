const std = @import("std");

pub const Ret = struct {
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

pub const system = struct {
    const ResetType = enum(u32) {
        shutdown = 0x00,
        cold_reboot = 0x01,
        warm_reboot = 0x02,
        _,
    };

    const ResetReason = enum(u32) {
        no_reason = 0x00,
        system_failure = 0x01,
        _,
    };

    pub fn reset(ty: ResetType, reason: ResetReason) Ret {
        return call(@intFromEnum(ty), @intFromEnum(reason), 0, 0, 0, 0, 0, 0x53525354);
    }
};

pub const console = struct {
    pub fn putChar(char: u8) void {
        _ = call(@intCast(char), 0, 0, 0, 0, 0, 0, 1);
    }

    pub fn writer() std.Io.Writer {
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
