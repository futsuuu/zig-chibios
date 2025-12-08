pub const block = @import("virtio/block.zig");
pub const mmio = @import("virtio/mmio.zig");

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
    _,
};
