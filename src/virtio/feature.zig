const std = @import("std");
const log = std.log.scoped(.virtio);

pub const Reserved = enum(u32) {
    indirect_descriptor = 28,
    event_index = 29,
    version_1 = 32,
    access_platform = 33,
    ring_packed = 34,
    in_order = 35,
    order_platform = 36,
    singleroot_io_virt = 37,
    notification_data = 38,
    notification_config_data = 39,
    ring_reset = 40,
    admin_virtqueue = 41,
};

pub fn Full(DeviceSpecific: type) type {
    return union(enum) {
        const Self = @This();

        reserved: Reserved,
        device: DeviceSpecific,

        pub const values = b: {
            var vals: []const Self = &.{};
            for (std.enums.values(Reserved)) |e| {
                vals = vals ++ [_]Self{.{ .reserved = e }};
            }
            for (std.enums.values(DeviceSpecific)) |e| {
                vals = vals ++ [_]Self{.{ .device = e }};
            }
            break :b vals;
        };
        const max_int = b: {
            var max = 0;
            for (values) |value| max = @max(max, value.toInt());
            break :b max;
        };

        pub fn toInt(self: Self) u32 {
            return switch (self) {
                inline else => |e| @intFromEnum(e),
            };
        }

        pub fn name(self: Self) []const u8 {
            return switch (self) {
                inline else => |e| @tagName(e),
            };
        }
    };
}
test Full {
    try std.testing.expect(Full(enum(u32) { bar = 1 }).max_int == 41);
    try std.testing.expect(Full(enum(u32) { foo = 1000 }).max_int == 1000);
    const f: Full(enum(u32) { bar = 7 }) = .{ .reserved = .version_1 };
    try std.testing.expect(f.toInt() == 32);
    try std.testing.expect(std.mem.eql(u8, f.name(), "version_1"));
}

pub fn Set(DeviceSpecific: type) type {
    const Feature = Full(DeviceSpecific);
    return struct {
        const Self = @This();

        array: [Feature.max_int / 32 + 1]u32,

        pub const uninit: Self = .{
            .array = undefined,
        };

        pub fn has(self: Self, feature: Feature) bool {
            const int = feature.toInt();
            const index = int >> 5;
            const bit_index: u5 = @truncate(int);
            return (self.array[index] >> bit_index) & 1 == 1;
        }

        pub fn unset(self: *Self, feature: Feature) void {
            const int = feature.toInt();
            const index = int >> 5;
            const bit_index: u5 = @truncate(int);
            self.array[index] &= ~(@as(u32, 1) << bit_index);
        }

        pub fn require(self: Self, feature: Feature) error{FeatureNotOffered}!void {
            if (!self.has(feature)) {
                log.err("required feature '{s}' is not offered by device", .{feature.name()});
                return error.FeatureNotOffered;
            }
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(@typeName(Self) ++ "{ ");
            for (Feature.values, 0..) |feature, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.print(".{s} = {}", .{ feature.name(), self.has(feature) });
            }
            try writer.writeAll(" }");
        }
    };
}
test Set {
    try std.testing.expect(Set(enum(u32) { x = 63 }).uninit.array.len == 2);
    try std.testing.expect(Set(enum(u32) { x = 64 }).uninit.array.len == 3);

    var set: Set(enum(u32) { a = 0, b = 1, c = 2, d = 3, x = 63 }) = .uninit;
    set.array[0] = 0b00000000_00000000_00000000_00000111;
    set.array[1] = 0b10000000_00000000_00000000_00000000;
    try std.testing.expect(set.has(.{ .device = .a }));
    try std.testing.expect(set.has(.{ .device = .b }));
    try std.testing.expect(set.has(.{ .device = .c }));
    try std.testing.expect(!set.has(.{ .device = .d }));
    try std.testing.expect(set.has(.{ .device = .x }));
    set.unset(.{ .device = .b });
    try std.testing.expect(set.has(.{ .device = .a }));
    try std.testing.expect(!set.has(.{ .device = .b }));
    try std.testing.expect(set.has(.{ .device = .c }));
    try std.testing.expect(!set.has(.{ .device = .d }));
    set.unset(.{ .device = .b });
    try std.testing.expect(!set.has(.{ .device = .b }));
}
