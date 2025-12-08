const std = @import("std");

pub fn Big(T: type) type {
    return Converter(T, .big);
}
pub fn Little(T: type) type {
    return Converter(T, .little);
}

fn Converter(T: type, endian: std.builtin.Endian) type {
    return packed struct {
        int: Int,

        const Int = std.meta.Int(.unsigned, @bitSizeOf(T));

        pub inline fn fromNative(x: T) @This() {
            const native: Int = switch (@typeInfo(T)) {
                .@"enum" => @intFromEnum(x),
                else => @bitCast(x),
            };
            return .{ .int = std.mem.nativeTo(Int, native, endian) };
        }

        pub inline fn toNative(self: @This()) T {
            const native = std.mem.toNative(Int, self.int, endian);
            return switch (@typeInfo(T)) {
                .@"enum" => @enumFromInt(native),
                else => @bitCast(native),
            };
        }
    };
}
