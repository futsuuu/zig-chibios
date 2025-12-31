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

pub fn Stream(UnionOfFeatures: type) type {
    const union_info = @typeInfo(UnionOfFeatures).@"union";
    std.debug.assert(union_info.tag_type != null);
    comptime var all_features: []const UnionOfFeatures = &.{};
    comptime var max_feature_index: u32 = 0;
    for (union_info.fields) |union_field| {
        const enum_info = @typeInfo(union_field.type).@"enum";
        std.debug.assert(enum_info.is_exhaustive);
        std.debug.assert(enum_info.tag_type == u32);
        for (enum_info.fields) |field| {
            all_features = all_features ++ [_]UnionOfFeatures{@unionInit(
                UnionOfFeatures,
                union_field.name,
                @enumFromInt(field.value),
            )};
            max_feature_index = @max(max_feature_index, field.value);
        }
    }
    const max_select = max_feature_index / 32 + 1;

    const feat = struct {
        fn name(feature: UnionOfFeatures) []const u8 {
            return switch (feature) {
                inline else => |f| @tagName(f),
            };
        }
        fn index(feature: UnionOfFeatures) u32 {
            return switch (feature) {
                inline else => |f| @intFromEnum(f),
            };
        }
    };

    return struct {
        const Self = @This();

        device: Device,
        driver: Driver,
        consumed: usize,

        pub const Device = struct {
            bits: [max_select]u32,

            fn isOffered(self: Device, feature: UnionOfFeatures) bool {
                const feature_index = feat.index(feature);
                const select = feature_index >> 5; // i / 32
                const bitidx: u5 = @truncate(feature_index); // i % 32
                return (self.bits[select] >> bitidx) & 1 == 1;
            }
        };

        pub const Driver = struct {
            bits: [max_select]u32,

            fn accept(self: *Driver, feature: UnionOfFeatures) void {
                const feature_index = feat.index(feature);
                const select = feature_index >> 5;
                const bitidx: u5 = @truncate(feature_index);
                self.bits[select] |= @as(u32, 1) << bitidx;
            }
        };

        pub const uninit: Self = .{
            .device = .{ .bits = undefined },
            .driver = .{ .bits = [_]u32{0} ** max_select },
            .consumed = 0,
        };

        pub fn next(self: *Self) bool {
            if (all_features.len <= self.consumed) return false;
            self.consumed += 1;
            if (std.log.logEnabled(.debug, .virtio)) {
                log.debug("device: {s} = {}", .{ feat.name(self.current()), self.isOffered() });
            }
            return true;
        }

        pub fn current(self: Self) UnionOfFeatures {
            return all_features[self.consumed - 1];
        }

        pub fn isOffered(self: Self) bool {
            return self.device.isOffered(self.current());
        }

        pub fn accept(self: *Self) error{FeatureNotOffered}!void {
            const feature = self.current();
            if (self.device.isOffered(feature)) {
                self.driver.accept(feature);
            } else {
                log.err("cannot accept feature that is not offered by device: {s}", .{feat.name(feature)});
                return error.FeatureNotOffered;
            }
        }

        pub fn inherit(self: *Self) void {
            const feature = self.current();
            if (self.device.isOffered(feature)) {
                self.driver.accept(feature);
            }
        }
    };
}

test Stream {
    var features: Stream(union(enum) {
        feat_a: enum(u32) { c = 2, d = 5, e = 54 },
        feat_b: enum(u32) { f = 32, g = 1 },
    }) = .uninit;
    try std.testing.expect(features.device.bits.len == 2);
    features.device.bits[0] = 0b00000000000000000000000000100000;
    features.device.bits[1] = 0b00000000010000000000000000000001;
    while (features.next()) {
        try std.testing.expect(switch (features.current()) {
            .feat_a => |a| switch (a) {
                .c => !features.isOffered(),
                .d => features.isOffered(),
                .e => features.isOffered(),
            },
            .feat_b => |b| switch (b) {
                .f => features.isOffered(),
                .g => !features.isOffered(),
            },
        });
        features.inherit();
    }
    try std.testing.expect(features.driver.bits[0] == 0b00000000000000000000000000100000);
    try std.testing.expect(features.driver.bits[1] == 0b00000000010000000000000000000001);
}
