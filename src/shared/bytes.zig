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

        pub fn alignForward(self: Self, alignment: usize) !void {
            return self.src.alignForward(alignment);
        }

        pub fn takePtr(self: Self, T: type) !*align(1) const T {
            _ = @typeInfo(extern struct { _: T }); // guaranteed in-memory representation is required
            const array = (try self.take(@sizeOf(T)))[0..@sizeOf(T)];
            const wrapper: *align(1) const T = @ptrCast(array);
            return wrapper;
        }

        pub fn takeInt(self: Self, T: type, endian: std.builtin.Endian) !T {
            const bytes = try self.take(@sizeOf(T));
            return std.mem.readInt(T, bytes[0..@sizeOf(T)], endian);
        }

        pub fn takeEnum(self: Self, T: type, endian: std.builtin.Endian) !T {
            const Backing = @typeInfo(T).@"enum".tag_type;
            return @enumFromInt(try self.takeInt(Backing, endian));
        }

        pub fn takeSentinel(self: Self, sentinel: u8) ![]const u8 {
            const avail = try self.remaining();
            const end = std.mem.indexOfScalar(u8, avail, sentinel) orelse return error.EndOfStream;
            const result = try self.take(end);
            _ = try self.take(1);
            return result;
        }
    };
}

test "Reader.takeInt" {
    var data: fixed.Readable = .init(&.{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06 });
    const r = wrapWithReader(&data);
    try std.testing.expectEqual(0x0001, try r.takeInt(u16, .big));
    try std.testing.expectEqual(0x0203, try r.takeInt(u16, .big));
    try std.testing.expectEqual(0x0405, try r.takeInt(u16, .big));
    try std.testing.expectError(error.EndOfStream, r.takeInt(u16, .big));
}

test "Reader.takeEnum" {
    const E = enum(u32) {
        a = 1,
        b = 2,
    };
    var data: fixed.Readable = .init(&.{ 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02 });
    const r = wrapWithReader(&data);
    try std.testing.expectEqual(E.a, try r.takeEnum(E, .big));
    try std.testing.expectEqual(E.b, try r.takeEnum(E, .big));
}

test "Reader.takeSentinel" {
    var data: fixed.Readable = .init(&.{ 'h', 'e', 'l', 'l', 'o', 0, 'w', 'o', 'r', 'l', 'd', 0 });
    const r = wrapWithReader(&data);
    try std.testing.expectEqualStrings("hello", try r.takeSentinel(0));
    try std.testing.expectEqualStrings("world", try r.takeSentinel(0));
}

test "Reader.takeSentinel empty" {
    var data: fixed.Readable = .init(&.{ 0, 'a', 0 });
    const r = wrapWithReader(&data);
    try std.testing.expectEqualStrings("", try r.takeSentinel(0));
    try std.testing.expectEqualStrings("a", try r.takeSentinel(0));
}

test "Reader.takeSentinel error on missing sentinel" {
    var data: fixed.Readable = .init(&.{ 'a', 'b', 'c' });
    const r = wrapWithReader(&data);
    try std.testing.expectError(error.EndOfStream, r.takeSentinel(0));
}

test "Reader.alignForward" {
    var data: fixed.Readable = .init(&.{ 0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x43 });
    const r = wrapWithReader(&data);
    try r.alignForward(4);
    try std.testing.expectEqual(0x42, try r.takeInt(u32, .big));
    try r.alignForward(4);
    const remaining = try r.remaining();
    try std.testing.expectEqual(0x43, std.mem.readInt(u32, remaining[0..4], .big));
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

        pub fn writeByte(self: Self, byte: u8) !void {
            return self.writeAll(&[_]u8{byte});
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

test "Writer.writeByte" {
    var buf: [4]u8 = undefined;
    var dest: fixed.Writable = .init(&buf);
    const w = wrapWithWriter(&dest);
    try w.writeByte('a');
    try w.writeByte('b');
    try w.writeByte('c');
    try std.testing.expectEqualStrings("abc", buf[0..3]);
}

pub const fixed = struct {
    pub const Readable = struct {
        data: []const u8,
        start_addr: usize,

        pub fn init(bytes: []const u8) Readable {
            return .{
                .data = bytes,
                .start_addr = @intFromPtr(bytes.ptr),
            };
        }

        pub fn take(self: *Readable, len: usize) error{EndOfStream}![]const u8 {
            if (self.data.len < len) return error.EndOfStream;
            defer self.data = self.data[len..];
            return self.data[0..len];
        }

        pub fn remaining(self: *Readable) []const u8 {
            return self.data;
        }

        pub fn alignForward(self: *Readable, alignment: usize) !void {
            const offset = @intFromPtr(self.data.ptr) - self.start_addr;
            const aligned = std.mem.alignForward(usize, offset, alignment);
            const diff = aligned - offset;
            if (0 < diff) _ = try self.take(diff);
        }
    };

    pub const Writable = struct {
        buf: []u8,
        cursor: usize = 0,

        pub fn init(bytes: []u8) Writable {
            return .{ .buf = bytes };
        }

        pub fn writeAll(self: *Writable, data: []const u8) !void {
            const buf = self.buf[self.cursor..];
            if (buf.len < data.len) return error.WriteFailed;
            @memcpy(buf[0..data.len], data);
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
