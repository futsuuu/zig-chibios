const std = @import("std");

pub fn Big(T: type) type {
    return Converter(T, .big);
}
pub fn Little(T: type) type {
    return Converter(T, .little);
}

fn Converter(T: type, endian: std.builtin.Endian) type {
    return packed struct {
        _inner: T,
        pub inline fn fromNative(x: T) @This() {
            return .{ ._inner = std.mem.nativeTo(T, x, endian) };
        }
        pub inline fn toNative(self: @This()) T {
            return std.mem.toNative(T, self._inner, endian);
        }
    };
}
