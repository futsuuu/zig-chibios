const std = @import("std");

pub fn init(comptime stderr_writer: std.Io.Writer) std.Io {
    const global = struct {
        const vtable: std.Io.VTable = blk: {
            var t: std.Io.VTable = std.Io.failing.vtable.*;
            t.swapCancelProtection = debugSwapCancelProtection;
            t.lockStderr = debugLockStderr;
            t.unlockStderr = debugUnlockStderr;
            break :blk t;
        };

        var file_writer: std.Io.File.Writer = .{
            .io = undefined,
            .file = .{
                .handle = {},
                .flags = .{ .nonblocking = false },
            },
            .interface = stderr_writer,
        };

        fn debugSwapCancelProtection(_: ?*anyopaque, _: std.Io.CancelProtection) std.Io.CancelProtection {
            return .blocked;
        }

        fn debugLockStderr(_: ?*anyopaque, terminal_mode: ?std.Io.Terminal.Mode) std.Io.Cancelable!std.Io.LockedStderr {
            return .{
                .file_writer = &file_writer,
                .terminal_mode = terminal_mode orelse .escape_codes,
            };
        }

        fn debugUnlockStderr(_: ?*anyopaque) void {
            file_writer.interface.flush() catch {};
            file_writer.interface.buffer = &.{};
        }
    };
    return .{
        .userdata = null,
        .vtable = &global.vtable,
    };
}
