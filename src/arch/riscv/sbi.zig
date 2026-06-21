const std = @import("std");

fn call(
    comptime eid: usize,
    comptime fid: usize,
    comptime Ret: type,
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    arg5: usize,
) error{
    Failed,
    NotSupported,
    InvalidParam,
    Denied,
    InvalidAddress,
    AlreadyAvailable,
    AlreadyStarted,
    AlreadyStopped,
    NoShmem,
    InvalidState,
    BadRange,
    Timeout,
    Io,
    DeniedLocked,
}!Ret {
    std.debug.assert(@sizeOf(Ret) == @sizeOf(usize));
    var err: isize = undefined;
    var val: Ret = undefined;
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
    return switch (err) {
        0 => val,
        -1 => error.Failed,
        -2 => error.NotSupported,
        -3 => error.InvalidParam,
        -4 => error.Denied,
        -5 => error.InvalidAddress,
        -6 => error.AlreadyAvailable,
        -7 => error.AlreadyStarted,
        -8 => error.AlreadyStopped,
        -9 => error.NoShmem,
        -10 => error.InvalidState,
        -11 => error.BadRange,
        -12 => error.Timeout,
        -13 => error.Io,
        -14 => error.DeniedLocked,
        else => unreachable,
    };
}

fn callLegacy(
    comptime eid: usize,
    arg0: usize,
    arg1: usize,
    arg2: usize,
    arg3: usize,
    arg4: usize,
    arg5: usize,
) isize {
    return asm volatile (
        \\ ecall
        : [r0] "={a0}" (-> isize),
        : [a0] "{a0}" (arg0),
          [a1] "{a1}" (arg1),
          [a2] "{a2}" (arg2),
          [a3] "{a3}" (arg3),
          [a4] "{a4}" (arg4),
          [a5] "{a5}" (arg5),
          [a6] "{a6}" (0),
          [a7] "{a7}" (eid),
        : .{ .memory = true });
}

test "error code" {
    try std.testing.expectError(error.NotSupported, call(base.eid, 99999, usize, 0, 0, 0, 0, 0, 0));
}

/// SBI version >= 0.2
pub const base = struct {
    const eid = 0x10;

    pub fn getSpecVersion() std.SemanticVersion {
        const Format = packed struct(usize) {
            minor: u24,
            major: u7,
            reserved: if (@bitSizeOf(usize) == 32) u1 else u33,
        };
        const ret = call(eid, 0, Format, 0, 0, 0, 0, 0, 0) catch unreachable;
        std.debug.assert(ret.reserved == 0);
        return .{
            .major = @intCast(ret.major),
            .minor = @intCast(ret.minor),
            .patch = 0,
        };
    }

    test getSpecVersion {
        try std.testing.expect(getSpecVersion().order(try .parse("2.0.0")) != .lt);
    }
};

/// SBI version >= 0.1
pub const legacy = struct {
    pub fn putChar(char: u8) error{SbiFailed}!void {
        if (callLegacy(1, @intCast(char), 0, 0, 0, 0, 0) != 0) {
            return error.SbiFailed;
        }
    }

    pub fn shutdown() error{SbiFailed}!noreturn {
        @branchHint(.cold);
        _ = callLegacy(8, 0, 0, 0, 0, 0, 0);
        return error.SbiFailed;
    }
};

/// SBI version >= 0.3
pub const system = struct {
    const eid = 0x53525354;

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

    pub fn reset(ty: ResetType, reason: ResetReason) error{ InvalidSbiParam, SbiFailed }!noreturn {
        @branchHint(.cold);
        _ = call(eid, 0, usize, @intFromEnum(ty), @intFromEnum(reason), 0, 0, 0, 0) catch |e| switch (e) {
            error.NotSupported => {
                try legacy.shutdown();
            },
            error.InvalidParam => return error.InvalidSbiParam,
            error.Failed => return error.SbiFailed,
            else => unreachable,
        };
        unreachable;
    }
};

/// SBI version >= 2.0
pub const debug_console = struct {
    const eid = 0x4442434E;

    pub fn write(bytes: []const u8) (error { InvalidSbiParam, NoWritableConsole } || std.Io.Writer.Error)!void {
        _ = call(eid, 0, usize, bytes.len, @intFromPtr(bytes.ptr), 0, 0, 0, 0) catch |e| switch (e) {
            error.NotSupported => {
                for (bytes) |byte| try writeByte(byte);
            },
            error.InvalidParam => return error.InvalidSbiParam,
            error.Denied => return error.NoWritableConsole,
            error.Failed => return error.WriteFailed,
            else => unreachable,
        };
    }

    pub fn writeByte(byte: u8) (error { InvalidSbiParam, NoWritableConsole } || std.Io.Writer.Error)!void {
        _ = call(eid, 2, usize, @intCast(byte), 0, 0, 0, 0, 0) catch |e| switch (e) {
            error.NotSupported => {
                _ = legacy.putChar(byte) catch return error.WriteFailed;
            },
            error.InvalidParam => return error.InvalidSbiParam,
            error.Denied => return error.NoWritableConsole,
            error.Failed => return error.WriteFailed,
            else => unreachable,
        };
    }

    pub fn writer() std.Io.Writer {
        return .{
            .buffer = &.{},
            .vtable = &.{
                .drain = drain,
                .flush = std.Io.Writer.defaultFlush,
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        if (w.end != 0) {
            write(w.buffer[0..w.end]) catch return error.WriteFailed;
            w.end = 0;
        }
        var written: usize = 0;
        for (data) |bytes| {
            written += bytes.len;
            write(bytes) catch return error.WriteFailed;
        }
        const last = data[data.len - 1];
        written += last.len * (splat - 1);
        for (0..splat - 1) |_| {
            write(last) catch return error.WriteFailed;
        }
        return written;
    }
};
