const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.virtio_mmio);

const endian = @import("../endian.zig");
const Le = endian.Little;
const qemu = @import("../qemu.zig");
const virtio = @import("../virtio.zig");

pub const RegisterHeader = struct {
    pub const expected_magic: u32 = @bitCast(std.mem.nativeToLittle([4]u8, "virt".*));
    pub const expected_version: u32 = 2;

    magic: RegisterField(0x00, .r, u32),
    version: RegisterField(0x04, .r, u32),
    device_id: RegisterField(0x08, .r, virtio.DeviceType),

    pub fn init(addr: usize) error{InvalidDevice}!*const RegisterHeader {
        const self: *const RegisterHeader = @ptrFromInt(addr);
        if (self.magic.read() != expected_magic) {
            log.err("invalid magic value 0x{x}", .{self.magic.read()});
            return error.InvalidDevice;
        }
        if (self.version.read() != expected_version) {
            log.err(
                "invalid device version 0x{x}: currently only supported version 0x{x}",
                .{ self.version.read(), expected_version },
            );
            return error.InvalidDevice;
        }
        return self;
    }
    test init {
        const header = try init(qemu.virt_virtio.base);
        try std.testing.expect(header.device_id.read() == .block);
    }
};

pub fn Register(Config: type, Feature: type) type {
    return struct {
        const Self = @This();
        comptime {
            assert(@sizeOf(Self) == 0);
        }

        magic: RegisterField(0x00, .r, u32),
        version: RegisterField(0x04, .r, u32),
        device_id: RegisterField(0x08, .r, virtio.DeviceType),
        vendor_id: RegisterField(0x0c, .r, u32),
        device_features: RegisterField(0x10, .r, u32),
        device_features_sel: RegisterField(0x14, .w, u32),
        driver_features: RegisterField(0x20, .w, u32),
        driver_features_sel: RegisterField(0x24, .w, u32),
        queue_sel: RegisterField(0x30, .w, u32),
        queue_notify: RegisterField(0x50, .w, QueueNotifier),
        interrupt_status: RegisterField(0x60, .r, u32),
        interrupt_ack: RegisterField(0x64, .w, u32),
        status: RegisterField(0x70, .rw, virtio.DeviceStatus),

        pub fn init(header: *const RegisterHeader) *Self {
            if (header.device_id.read() == .reserved) {
                std.debug.panic("device with DeviceID 0x0 should be ignored", .{});
            }
            return @ptrCast(@constCast(header));
        }

        pub fn config(self: *Self) *Config {
            return @ptrFromInt(@intFromPtr(self) + 0x100);
        }

        pub fn readDeviceFeatures(self: *Self) virtio.feature.Set(Feature) {
            var set: virtio.feature.Set(Feature) = .uninit;
            for (0..set.array.len) |i| {
                self.device_features_sel.write(@intCast(i));
                set.array[i] = self.device_features.read();
            }
            return set;
        }

        pub fn writeDriverFeatures(self: *Self, set: virtio.feature.Set(Feature)) void {
            for (0..set.array.len) |i| {
                self.driver_features_sel.write(@intCast(i));
                self.driver_features.write(set.array[i]);
            }
        }

        pub fn selectQueue(self: *Self, index: u16) error{QueueNotAvailable}!*SelectedQueueRegister {
            self.queue_sel.write(@intCast(index));
            const selected: *SelectedQueueRegister = @ptrCast(self);
            if (selected.ready.read() != 0) {
                log.err("virtqueue is already in use", .{});
                return error.QueueNotAvailable;
            }
            if (selected.size_max.read() == 0) {
                log.err("QueueSizeMax is zero", .{});
                return error.QueueNotAvailable;
            }
            return selected;
        }
    };
}

pub const SelectedQueueRegister = struct {
    size_max: RegisterField(0x34, .r, u32),
    size: RegisterField(0x38, .w, u32),
    ready: RegisterField(0x44, .rw, u32),
    desc_low: RegisterField(0x80, .w, u32),
    desc_high: RegisterField(0x84, .w, u32),
    driver_low: RegisterField(0x90, .w, u32),
    driver_high: RegisterField(0x94, .w, u32),
    device_low: RegisterField(0xa0, .w, u32),
    device_high: RegisterField(0xa4, .w, u32),

    pub fn setAddr(
        self: *SelectedQueueRegister,
        area: enum { desc, driver, device },
        addr: usize,
    ) void {
        const high, const low = splitAddr(addr);
        switch (area) {
            .desc => {
                self.desc_high.write(high);
                self.desc_low.write(low);
            },
            .driver => {
                self.driver_high.write(high);
                self.driver_low.write(low);
            },
            .device => {
                self.device_high.write(high);
                self.device_low.write(low);
            },
        }
    }
};

fn splitAddr(addr: usize) struct { u32, u32 } {
    return switch (comptime builtin.target.ptrBitWidth()) {
        32 => .{ 0, @intCast(addr) },
        64 => .{ @intCast(addr >> 32), @truncate(addr) },
        else => unreachable,
    };
}

pub const QueueNotifier = packed union {
    index: u16,
    /// Used when VIRTIO_F_NOTIFICATION_DATA has been negotiated.
    data: packed struct(u32) {
        vq_index: u16,
        next_offset: u15,
        next_wrap: bool,
    },
};

fn RegisterField(offset: usize, direction: enum { r, w, rw }, T: type) type {
    assert(@bitSizeOf(T) == 32);
    return struct {
        _: void = {},

        pub inline fn read(self: *const @This()) T {
            comptime assert(direction != .w);
            const ptr: *const volatile Le(T) = @ptrFromInt(@intFromPtr(self) + offset);
            return ptr.toNative();
        }

        pub inline fn write(self: *@This(), value: T) void {
            comptime assert(direction != .r);
            const ptr: *volatile Le(T) = @ptrFromInt(@intFromPtr(self) + offset);
            ptr.* = .fromNative(value);
        }

        pub inline fn writeBit(self: *@This(), bitflags: T) void {
            const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
            const lhs: Int = @bitCast(self.read());
            const rhs: Int = @bitCast(bitflags);
            self.write(@bitCast(lhs | rhs));
        }
    };
}
