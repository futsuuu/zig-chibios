const std = @import("std");
const log = std.log.scoped(.virtio);

pub const Queue = @import("virtio/Queue.zig");
pub const block = @import("virtio/block.zig");
pub const feature = @import("virtio/feature.zig");
pub const mmio = @import("virtio/mmio.zig");

pub fn init() !void {
    const qemu = @import("qemu.zig");
    const reg_header = try mmio.RegisterHeader.init(qemu.virt_test.base);
    switch (reg_header.device_id.read()) {
        .reserved => return,
        .block => {
            const register = mmio.Register(block.Config).init(reg_header);
            register.status.write(.reset);
            register.status.writeBit(.{ .acknowledge = true });
            errdefer register.status.writeBit(.{ .failed = true });

            register.status.writeBit(.{ .driver = true });

            var features: feature.Stream(union(enum) {
                reserved: feature.Reserved,
                block: block.Features,
            }) = .uninit;
            for (0..features.device.bits.len) |i| {
                register.device_features_sel.write(@intCast(i));
                features.device.bits[i] = register.device_features.read();
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
                register.driver_features_sel.write(@intCast(i));
                register.driver_features.write(features.driver.bits[i]);
            }
            // TODO: check device-specific configuration fields (Read-Only) before accepting it if needed
            register.status.writeBit(.{ .features_ok = true });
            if (!register.status.read().features_ok) {
                log.err("device is unusable: FEATURES_OK status bit was removed by the device", .{});
                return error.UnusableDevice;
            }

            // Perform device-specific setup, including discovery of virtqueues for the device, optional per-bus setup,
            // reading and possibly writing the device’s virtio configuration space, and population of virtqueues.
            register.queue_sel.write(0);
            if (register.queue_ready.read() != 0) {
                log.err("virtqueue is already in use", .{});
                return error.QueueNotAvailable;
            }
            const queue_size_max = register.queue_size_max.read();
            if (queue_size_max == 0) {
                log.err("QueueSizeMax is zero", .{});
                return error.QueueNotAvailable;
            }
            // Allocate and zero the queue memory, making sure the memory is physically contiguous.
            register.queue_ready.write(1);

            register.status.writeBit(.{ .driver_ok = true });
        },
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
