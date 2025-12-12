const std = @import("std");
const log = std.log.scoped(.virtio);

pub const Queue = @import("virtio/Queue.zig");
pub const block = @import("virtio/block.zig");
pub const mmio = @import("virtio/mmio.zig");

pub fn init() !void {
    const qemu = @import("qemu.zig");
    switch (try mmio.Register.fromAddr(qemu.virt_test.base)) {
        .block => |register| {
            register.status.set(.reset);
            register.status.setBit(.{ .acknowledge = true });
            errdefer register.status.setBit(.{ .failed = true });

            register.status.setBit(.{ .driver = true });

            var features: FeatureStream(union(enum) {
                reserved: ReservedFeatures,
                block: block.Features,
            }) = .uninitialized;
            for (0..features.device.bits.len) |i| {
                register.device_features_sel.set(@truncate(i));
                features.device.bits[i] = register.device_features.get();
            }
            while (features.next()) switch (features.current()) {
                .reserved => |f| switch (f) {
                    .version_1,
                    // TODO: remove following requrements
                    .ring_packed,
                    => try features.accept(),
                    else => features.inherit(),
                },
                .block => |f| switch (f) {
                    .multiqueue => {},
                    else => features.inherit(),
                },
            };
            for (0..features.driver.bits.len) |i| {
                register.driver_features_sel.set(@truncate(i));
                register.driver_features.set(features.driver.bits[i]);
            }
            // TODO: check device-specific configuration fields (Read-Only) before accepting it if needed
            register.status.setBit(.{ .features_ok = true });
            if (!register.status.get().features_ok) {
                log.err("device is unusable: FEATURES_OK status bit was removed by the device", .{});
                return error.UnusableDevice;
            }

            // Perform device-specific setup, including discovery of virtqueues for the device, optional per-bus setup,
            // reading and possibly writing the device’s virtio configuration space, and population of virtqueues.
            register.queue_sel.set(0);
            if (register.queue_ready.get() != 0) {
                log.err("virtqueue is already in use", .{});
                return error.QueueNotAvailable;
            }
            const queue_size_max = register.queue_size_max.get();
            if (queue_size_max == 0) {
                log.err("QueueSizeMax is zero", .{});
                return error.QueueNotAvailable;
            }
            // Allocate and zero the queue memory, making sure the memory is physically contiguous.
            register.queue_ready.set(1);

            register.status.setBit(.{ .driver_ok = true });
        },
        else => @panic("unimplemented"),
    }
}

pub const DeviceStatus = packed struct(u8) {
    // 1
    acknowledge: bool = false,
    // 2
    driver: bool = false,
    // 4
    driver_ok: bool = false,
    // 8
    features_ok: bool = false,
    _: u2 = 0,
    // 64
    needs_reset: bool = false,
    // 128
    failed: bool = false,

    pub const reset: DeviceStatus = .{};
};

pub const DeviceType = enum(u32) {
    reserved = 0,
    block = 2,
};

pub const ReservedFeatures = enum(u32) {
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

pub fn FeatureStream(UnionOfFeatures: type) type {
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

    const Device = struct {
        bits: [max_select]u32,

        fn isOffered(self: *const @This(), feature: UnionOfFeatures) bool {
            const feature_index = feat.index(feature);
            const select = feature_index >> 5; // i / 32
            const bitidx: u5 = @truncate(feature_index); // i % 32
            return (self.bits[select] >> bitidx) & 1 == 1;
        }
    };

    const Driver = struct {
        bits: [max_select]u32,

        fn accept(self: *@This(), feature: UnionOfFeatures) void {
            const feature_index = feat.index(feature);
            const select = feature_index >> 5;
            const bitidx: u5 = @truncate(feature_index);
            self.bits[select] |= @as(u32, 1) << bitidx;
        }
    };

    return struct {
        device: Device,
        driver: Driver,
        consumed: usize,

        const Stream = @This();

        const uninitialized: Stream = .{
            .device = .{ .bits = undefined },
            .driver = .{ .bits = [_]u32{0} ** max_select },
            .consumed = 0,
        };

        fn next(self: *Stream) bool {
            if (all_features.len <= self.consumed) return false;
            self.consumed += 1;
            if (std.log.logEnabled(.debug, .virtio)) {
                log.debug("device: {s} = {}", .{ feat.name(self.current()), self.isOffered() });
            }
            return true;
        }

        fn current(self: *const Stream) UnionOfFeatures {
            return all_features[self.consumed - 1];
        }

        fn isOffered(self: *const Stream) bool {
            return self.device.isOffered(self.current());
        }

        fn accept(self: *Stream) error{FeatureNotOffered}!void {
            const feature = self.current();
            if (self.device.isOffered(feature)) {
                self.driver.accept(feature);
            } else {
                log.err("cannot accept feature that is not offered by device: {s}", .{feat.name(feature)});
                return error.FeatureNotOffered;
            }
        }

        fn inherit(self: *Stream) void {
            const feature = self.current();
            if (self.device.isOffered(feature)) {
                self.driver.accept(feature);
            }
        }
    };
}

test FeatureStream {
    var features: FeatureStream(union(enum) {
        feat_a: enum(u32) { c = 2, d = 5, e = 54 },
        feat_b: enum(u32) { f = 32, g = 1 },
    }) = .uninitialized;
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
