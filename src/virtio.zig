const std = @import("std");
const log = std.log.scoped(.virtio);

pub const Queue = @import("virtio/Queue.zig");
pub const block = @import("virtio/block.zig");
pub const feature = @import("virtio/feature.zig");
pub const mmio = @import("virtio/mmio.zig");

pub const InitError = error{
    OutOfMemory,
    InvalidDevice,
    UnsupportedDevice,
    QueueAlreadyInUse,
};

pub fn init(address: usize) InitError!?union(enum) {
    block: block.Driver,
} {
    errdefer log.err("initialization failed", .{});
    const reg_header: *const mmio.RegisterHeader = try .init(address);
    return switch (reg_header.device_id.read()) {
        .reserved => null,
        .block => .{ .block = try .init(reg_header) },
        else => |ty| {
            log.err("unimplemented device type: {}", .{ty});
            return error.UnsupportedDevice;
        },
    };
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
