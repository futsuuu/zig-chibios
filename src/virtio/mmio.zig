const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.virtio_mmio);

const qemu = @import("../qemu.zig");
const virtio = @import("../virtio.zig");

pub const RegisterHeader = struct {
    pub const expected_magic: u32 = @bitCast(std.mem.nativeToLittle([4]u8, "virt".*));
    pub const expected_version: u32 = 2;

    magic: RegisterField(u32, .{ .offset = 0x00, .permission = .r }),
    version: RegisterField(u32, .{ .offset = 0x04, .permission = .r }),
    device_id: RegisterField(virtio.DeviceType, .{ .offset = 0x08, .permission = .r }),

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
        const header = try init(qemu.virt_test.base);
        try std.testing.expect(header.device_id.read() == .block);
    }
};

pub fn Register(Config: type) type {
    return struct {
        const Self = @This();
        comptime {
            assert(@sizeOf(Self) == 0);
        }

        magic: RegisterField(u32, .{ .offset = 0x00, .permission = .r }),
        version: RegisterField(u32, .{ .offset = 0x04, .permission = .r }),
        device_id: RegisterField(virtio.DeviceType, .{ .offset = 0x08, .permission = .r }),
        vendor_id: RegisterField(u32, .{ .offset = 0x0c, .permission = .r }),
        device_features: RegisterField(u32, .{ .offset = 0x10, .permission = .r }),
        device_features_sel: RegisterField(u32, .{ .offset = 0x14, .permission = .w }),
        driver_features: RegisterField(u32, .{ .offset = 0x20, .permission = .w }),
        driver_features_sel: RegisterField(u32, .{ .offset = 0x24, .permission = .w }),
        queue_sel: RegisterField(u32, .{ .offset = 0x30, .permission = .w }),
        queue_size_max: RegisterField(u32, .{ .offset = 0x34, .permission = .r }),
        queue_size: RegisterField(u32, .{ .offset = 0x38, .permission = .w }),
        queue_ready: RegisterField(u32, .{ .offset = 0x44, .permission = .rw }),
        queue_notify: RegisterField(QueueNotifier, .{ .offset = 0x50, .permission = .w }),
        interrupt_status: RegisterField(u32, .{ .offset = 0x60, .permission = .r }),
        interrupt_ack: RegisterField(u32, .{ .offset = 0x64, .permission = .w }),
        status: RegisterField(virtio.DeviceStatus, .{ .offset = 0x70, .permission = .rw, .bit_size = 32 }),
        queue_desc_low: RegisterField(u32, .{ .offset = 0x80, .permission = .w }),
        queue_desc_high: RegisterField(u32, .{ .offset = 0x84, .permission = .w }),
        queue_driver_low: RegisterField(u32, .{ .offset = 0x90, .permission = .w }),
        queue_driver_high: RegisterField(u32, .{ .offset = 0x94, .permission = .w }),
        queue_device_low: RegisterField(u32, .{ .offset = 0xa0, .permission = .w }),
        queue_device_high: RegisterField(u32, .{ .offset = 0xa4, .permission = .w }),
        config: RegisterField(Config, .{ .offset = 0x100, .permission = .rw, .endian = .native }),

        pub fn init(header: *const RegisterHeader) *Self {
            if (header.device_id.read() == .reserved) {
                std.debug.panic("device with DeviceID 0x0 should be ignored", .{});
            }
            return @ptrCast(@constCast(header));
        }
    };
}

pub const QueueNotifier = packed union {
    index: u32,
    /// Used when VIRTIO_F_NOTIFICATION_DATA has been negotiated.
    data: packed struct(u32) {
        vq_index: u16,
        next_offset: u15,
        next_wrap: bool,
    },
};

fn RegisterField(T: type, opts: struct {
    offset: usize,
    permission: enum { r, w, rw },
    bit_size: ?u16 = null,
    endian: enum { native, little } = .little,
}) type {
    const bit_size = opts.bit_size orelse @bitSizeOf(T);
    const Wrapper = packed struct {
        value: T,
        padding: std.meta.Int(.unsigned, bit_size - @bitSizeOf(T)) = 0,
    };
    if (opts.bit_size) |b| {
        assert(@bitSizeOf(Wrapper) == b);
    }

    return struct {
        _: u0,

        pub inline fn raw(self: *@This()) *T {
            comptime assert(opts.permission == .rw);
            comptime assert(opts.endian == .native);
            return @ptrFromInt(@intFromPtr(self) + opts.offset);
        }

        pub inline fn read(self: *const @This()) T {
            comptime assert(opts.permission != .w);
            const ptr: *const volatile Wrapper = @ptrFromInt(@intFromPtr(self) + opts.offset);
            return switch (opts.endian) {
                .native => ptr.value,
                .little => std.mem.littleToNative(Wrapper, ptr.*).value,
            };
        }

        pub inline fn write(self: *@This(), value: T) void {
            comptime assert(opts.permission != .r);
            const ptr: *volatile Wrapper = @ptrFromInt(@intFromPtr(self) + opts.offset);
            ptr.* = switch (opts.endian) {
                .native => .{ .value = value },
                .little => std.mem.nativeToLittle(Wrapper, .{ .value = value }),
            };
        }

        pub inline fn writeBit(self: *@This(), bitflags: T) void {
            const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
            const lhs: Int = @bitCast(self.read());
            const rhs: Int = @bitCast(bitflags);
            self.write(@bitCast(lhs | rhs));
        }
    };
}
