const std = @import("std");
const log = std.log.scoped(.virtio);

pub const Queue = @import("virtio/Queue.zig");
pub const block = @import("virtio/block.zig");
pub const feature = @import("virtio/feature.zig");
pub const mmio = @import("virtio/mmio.zig");

pub fn request(
    virtq: *Queue,
    register: *mmio.Register(block.Config),
    comptime t: enum { read, write },
    buf: switch (t) {
        .read => []u8,
        .write => []const u8,
    },
    sector: u64,
) block.RequestStatus.Error!void {
    const req_header: block.RequestHeader = .init(switch (t) {
        .read => .read,
        .write => .write,
    }, sector);
    var status: block.RequestStatus = undefined;
    const first_desc = virtq.append(std.mem.asBytes(&req_header), .{ .next = true });
    const body_desc = switch (t) {
        .read => virtq.appendWritable(buf, .{ .next = true }),
        .write => virtq.append(buf, .{ .next = true }),
    };
    const status_desc = virtq.appendWritable(std.mem.asBytes(&status), .{});
    status_desc.id = .fromNative(1);
    virtq.markAsAvailable(body_desc);
    virtq.markAsAvailable(status_desc);
    asm volatile ("fence rw, w" ::: .{ .memory = true });
    virtq.markAsAvailable(first_desc);

    asm volatile ("fence rw, rw" ::: .{ .memory = true });
    if (virtq.device_event.getEnabled()) |_| {
        register.queue_notify.write(.{ .index = virtq.index });
    }
    while (!virtq.isUsed(first_desc)) {
        asm volatile ("nop");
    }
    return status.ensureOk();
}

pub fn init(a: std.mem.Allocator) !?struct { Queue, *mmio.Register(block.Config) } {
    const qemu = @import("qemu.zig");
    const reg_header = try mmio.RegisterHeader.init(qemu.virt_test.base);
    switch (reg_header.device_id.read()) {
        .reserved => return null,
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
                    .notification_data,
                    .notification_config_data,
                    => {},
                    else => features.inherit(),
                },
                .block => |f| switch (f) {
                    .flush,
                    .zoned,
                    => {},
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

            const queue = b: {
                const queue_register = try register.selectQueue(0);
                defer queue_register.ready.write(1);
                const queue = try Queue.init(a, 0, queue_register.size_max.read());
                queue_register.size.write(@intCast(queue.desc_ring.len));
                queue_register.setAddr(.desc, queue.getAddr(.desc));
                queue_register.setAddr(.driver, queue.getAddr(.driver));
                queue_register.setAddr(.device, queue.getAddr(.device));
                break :b queue;
            };

            register.status.writeBit(.{ .driver_ok = true });

            return .{ queue, register };
        },
    }
}

pub const DeviceStatus = packed struct(u32) {
    // 1
    acknowledge: bool = false,
    // 2
    driver: bool = false,
    // 4
    driver_ok: bool = false,
    // 8
    features_ok: bool = false,
    _0: u2 = 0,
    // 64
    needs_reset: bool = false,
    // 128
    failed: bool = false,
    _1: u24 = 0,

    pub const reset: DeviceStatus = .{};
};

pub const DeviceType = enum(u32) {
    reserved = 0,
    block = 2,
};
