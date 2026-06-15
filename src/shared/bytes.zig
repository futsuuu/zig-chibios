const std = @import("std");

pub fn wrapWithReader(src: anytype) Reader(@TypeOf(src)) {
    return .{ .src = src };
}

pub fn wrapWithWriter(dest: anytype) Writer(@TypeOf(dest)) {
    return .{ .dest = dest };
}

pub fn Reader(Src: type) type {
    return struct {
        const Self = @This();

        src: Src,

        pub fn take(self: Self, len: usize) ![]const u8 {
            return self.src.take(len);
        }

        pub fn remaining(self: Self) ![]const u8 {
            return self.src.remaining();
        }

        pub fn takeArray(self: Self, comptime len: usize) !*const [len]u8 {
            return (try self.take(len))[0..len];
        }

        pub fn takeStruct(self: Self, T: type) !*align(1) const T {
            comptime std.debug.assert(@typeInfo(T).@"struct".layout == .@"extern");
            return @ptrCast(try self.takeArray(@sizeOf(T)));
        }
    };
}

pub fn Writer(Dest: type) type {
    return struct {
        const Self = @This();

        dest: Dest,

        pub fn write(self: Self, data: []const u8) !usize {
            if (!std.meta.hasMethod(Dest, "write")) {
                try asErrorUnion(self.dest.writeAll(data));
                return data.len;
            }
            return self.dest.write(data);
        }

        pub fn writeAll(self: Self, data: []const u8) !void {
            if (std.meta.hasMethod(Dest, "writeAll")) {
                return self.dest.writeAll(data);
            }
            var index: usize = 0;
            while (index < data.len) {
                index += try self.write(data[index..]);
            }
        }

        pub fn writeStruct(self: Self, data: anytype) !void {
            const T = @TypeOf(data);
            if (@typeInfo(T) != .pointer) {
                return writeStruct(self, &data);
            }
            switch (@typeInfo(@typeInfo(T).pointer.child)) {
                .@"struct" => |info| switch (info.layout) {
                    .@"extern" => return self.writeAll(@ptrCast(data[0..1])),
                    else => @compileError("unsupported struct layout"),
                },
                else => @compileError("not a struct"),
            }
        }
    };
}

pub const fixed = struct {
    pub const Readable = struct {
        data: []const u8,

        pub fn init(bytes: []const u8) Readable {
            return .{ .data = bytes };
        }

        pub fn take(self: *Readable, len: usize) error{EndOfStream}![]const u8 {
            if (self.data.len < len) return error.EndOfStream;
            defer self.data = self.data[len..];
            return self.data[0..len];
        }

        pub fn remaining(self: *Readable) []const u8 {
            return self.data;
        }
    };

    pub const Writable = struct {
        buf: []u8,
        cursor: usize = 0,

        pub fn init(bytes: []u8) Writable {
            return .{ .buf = bytes };
        }

        pub fn writeAll(self: *Writable, data: []const u8) std.Io.Writer.Error!void {
            const buf = self.buf[self.cursor..];
            if (buf.len < data.len) return error.WriteFailed;
            @memcpy(buf, data);
            self.cursor += data.len;
        }
    };
};

pub const alloc = struct {
    pub const Writable = struct {
        buf: std.ArrayList(u8),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Writable {
            return .{
                .allocator = allocator,
                .buf = .empty,
            };
        }

        pub fn deinit(self: *Writable) void {
            self.buf.deinit(self.allocator);
        }

        pub fn writeAll(self: *Writable, data: []const u8) std.mem.Allocator.Error!void {
            return self.buf.appendSlice(self.allocator, data);
        }

        pub fn written(self: *Writable) []const u8 {
            return self.buf.items;
        }

        pub fn clear(self: *Writable) void {
            self.buf.clearRetainingCapacity();
        }
    };
};

fn asErrorUnion(res: anytype) switch (@typeInfo(@TypeOf(res))) {
    .error_union => @TypeOf(res),
    .error_set => @TypeOf(res)!void,
    else => error{}!@TypeOf(res),
} {
    return res;
}

test asErrorUnion {
    try std.testing.expectEqual(
        1,
        asErrorUnion(@as(usize, 1)) catch comptime unreachable,
    );
    try std.testing.expectError(
        error.A,
        asErrorUnion(@as(error{ A, B }, error.A)),
    );
}
