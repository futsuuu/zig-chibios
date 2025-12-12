const std = @import("std");
const log = std.log.scoped(.virtio_mmio);

const qemu = @import("../qemu.zig");
const virtio = @import("../virtio.zig");

const magic: u32 = ('v' << 0) + ('i' << 8) + ('r' << 16) + ('t' << 24);
const supported_version: u32 = 2;

pub const Register = union(virtio.DeviceType) {
    reserved: void,
    block: *RegisterFields(virtio.block.Config),

    pub fn fromAddr(addr: usize) !Register {
        const reg: *RegisterFields(void) = @ptrFromInt(addr);
        if (reg.magic.get() != magic) {
            log.err("invalid magic value 0x{x}", .{reg.magic.get()});
            return error.InvalidDevice;
        }
        if (reg.version.get() != supported_version) {
            log.err(
                "invalid device version 0x{x}: currently only supported version 0x{x}",
                .{ reg.version.get(), supported_version },
            );
            return error.InvalidDevice;
        }
        return switch (reg.device_id.get()) {
            .reserved => .reserved,
            inline else => |t| @unionInit(Register, @tagName(t), @ptrCast(reg)),
        };
    }
    test fromAddr {
        switch (try fromAddr(qemu.virt_test.base)) {
            .block => |reg| try std.testing.expect(reg.magic.get() == magic),
            else => unreachable,
        }
    }
};

pub fn RegisterFields(Config: type) type {
    _ = Config;
    const T = struct {
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
        queue_notify: RegisterField(u32, .{ .offset = 0x50, .permission = .w }),
        interrupt_status: RegisterField(u32, .{ .offset = 0x60, .permission = .r }),
        interrupt_ack: RegisterField(u32, .{ .offset = 0x64, .permission = .w }),
        status: RegisterField(virtio.DeviceStatus, .{ .offset = 0x70, .permission = .rw, .bit_size = 32 }),
        queue_desc_low: RegisterField(u32, .{ .offset = 0x80, .permission = .w }),
        queue_desc_high: RegisterField(u32, .{ .offset = 0x84, .permission = .w }),
    };
    std.debug.assert(@sizeOf(T) == 0);
    return T;
}

fn RegisterField(T: type, opts: struct {
    offset: usize,
    permission: enum { r, w, rw },
    bit_size: ?u16 = null,
}) type {
    const bit_size = opts.bit_size orelse @bitSizeOf(T);
    const Wrapper = packed struct {
        value: T,
        padding: std.meta.Int(.unsigned, bit_size - @bitSizeOf(T)) = 0,
    };
    if (opts.bit_size) |b| {
        std.debug.assert(@bitSizeOf(Wrapper) == b);
    }

    return struct {
        _: u0,

        pub inline fn get(self: *const @This()) T {
            if (opts.permission == .w) @compileError("cannot read from write-only register");
            const ptr: *const volatile Wrapper = @ptrFromInt(@intFromPtr(self) + opts.offset);
            return std.mem.littleToNative(Wrapper, ptr.*).value;
        }

        pub inline fn set(self: *@This(), value: T) void {
            if (opts.permission == .r) @compileError("cannot write to read-only register");
            const ptr: *volatile Wrapper = @ptrFromInt(@intFromPtr(self) + opts.offset);
            ptr.* = std.mem.nativeToLittle(Wrapper, .{ .value = value });
        }

        pub inline fn setBit(self: *@This(), bitflags: T) void {
            const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
            const lhs: Int = @bitCast(self.get());
            const rhs: Int = @bitCast(bitflags);
            self.set(@bitCast(lhs | rhs));
        }
    };
}
