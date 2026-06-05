const std = @import("std");
const log = std.log.scoped(.virtio);

pub const Queue = @import("virtio/Queue.zig");
pub const block = @import("virtio/block.zig");
pub const feature = @import("virtio/feature.zig");
pub const mmio = @import("virtio/mmio.zig");

pub fn request(
    virtq: *Queue,
    register: *mmio.Register(block.Config, block.Feature),
    comptime t: enum { read, write },
    buf: switch (t) {
        .read => []u8,
        .write => []const u8,
    },
    sector: u64,
) block.RequestStatus.Error!void {
    const header: block.RequestHeader = switch (t) {
        .read => .init(.read, sector),
        .write => .init(.write, sector),
    };
    var status: block.RequestStatus = undefined;
    const header_desc = virtq.append(.readonly, std.mem.asBytes(&header), .{ .next = true });
    const body_desc = switch (t) {
        .read => virtq.append(.writable, buf, .{ .next = true }),
        .write => virtq.append(.readonly, buf, .{ .next = true }),
    };
    const status_desc = virtq.append(.writable, std.mem.asBytes(&status), .{});
    status_desc.id = .fromNative(1);
    virtq.markAsAvailable(body_desc);
    virtq.markAsAvailable(status_desc);
    asm volatile ("fence rw, w" ::: .{ .memory = true });
    virtq.markAsAvailable(header_desc);

    asm volatile ("fence rw, rw" ::: .{ .memory = true });
    if (virtq.device_event.getEnabled()) |_| {
        register.queue_notify.write(.{ .vq_index = virtq.index, .data = undefined });
    }
    while (!virtq.isUsed(header_desc)) {
        std.atomic.spinLoopHint();
    }
    return status.ensureOk();
}

pub fn init(a: std.mem.Allocator, address: usize) !?struct { Queue, *mmio.Register(block.Config, block.Feature) } {
    errdefer log.err("initialization failed", .{});
    const reg_header: *const mmio.RegisterHeader = try .init(address);
    switch (reg_header.device_id.read()) {
        .reserved => return null,
        .block => {
            const register: *mmio.Register(block.Config, block.Feature) = .init(reg_header);
            register.status.write(.reset);
            register.status.writeBit(.{ .acknowledge = true });
            errdefer register.status.writeBit(.{ .failed = true });

            register.status.writeBit(.{ .driver = true });

            var features = register.readDeviceFeatures();
            log.debug("device features: {f}", .{features});
            try features.require(.{ .reserved = .version_1 });
            try features.require(.{ .reserved = .ring_packed });
            features.unset(.{ .reserved = .notification_data });
            features.unset(.{ .reserved = .notification_config_data });
            features.unset(.{ .device = .flush });
            features.unset(.{ .device = .zoned });
            register.writeDriverFeatures(features);
            log.debug("driver features: {f}", .{features});
            register.status.writeBit(.{ .features_ok = true });
            if (!register.status.read().features_ok) {
                log.err("device is unusable: FEATURES_OK status bit was removed by the device", .{});
                return error.UnusableDevice;
            }

            const queue = b: {
                const queue_register = try register.selectQueue(0);
                defer queue_register.ready.write(1);
                const queue: Queue = try .init(a, 0, queue_register.size_max.read());
                queue_register.size.write(@intCast(queue.desc_ring.len));
                queue_register.setAddr(.desc, queue.getAddr(.desc));
                queue_register.setAddr(.driver, queue.getAddr(.driver));
                queue_register.setAddr(.device, queue.getAddr(.device));
                break :b queue;
            };

            register.status.writeBit(.{ .driver_ok = true });

            return .{ queue, register };
        },
        else => |ty| {
            log.err("unimplemented device type: {}", .{ty});
            return null;
        }
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
    network = 1,
    block = 2,
    console = 3,
    entropy_source = 4,
    traditional_memory_balloon = 5,
    io_memory = 6,
    rpmsg = 7,
    scsi_host = 8,
    transport_9p = 9,
    mac80211_wlan = 10,
    rproc_serial = 11,
    virtio_caif = 12,
    memory_balloon = 13,
    gpu = 16,
    timer_clock = 17,
    input = 18,
    socket = 19,
    crypto = 20,
    signal_distribution_module = 21,
    pstore = 22,
    iommu = 23,
    memory = 24,
    sound = 25,
    file_system = 26,
    pmem = 27,
    rpmb = 28,
    mac80211_hwsim_wireless_simulation = 29,
    video_encoder = 30,
    video_decoder = 31,
    scmi = 32,
    mitro_secure_module = 33,
    i2c_adapter = 34,
    watchdog = 35,
    can = 36,
    parameter_server = 38,
    audio_policy_device = 39,
    bluetooth = 40,
    gpio = 41,
    rdma = 42,
    camera = 43,
    ism = 44,
    spi_master = 45,
};

comptime {
    std.testing.refAllDecls(@This());
}
