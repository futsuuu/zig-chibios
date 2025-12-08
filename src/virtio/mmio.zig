const std = @import("std");
const log = std.log.scoped(.virtio_mmio);

const qemu = @import("../qemu.zig");
const virtio = @import("../virtio.zig");

const magic: u32 = ('v' << 0) + ('i' << 8) + ('r' << 16) + ('t' << 24);
const supported_version: u32 = 2;

pub fn getDeviceType(addr: usize) !virtio.DeviceType {
    const reg: *Register(void) = @ptrFromInt(addr);
    if (reg.magic.get() != magic) {
        log.err("invalid magic value: {x}", .{reg.magic.get()});
        return error.InvalidDevice;
    }
    if (reg.version.get() != supported_version) {
        log.err("invalid device version: {x}", .{reg.version.get()});
        return error.InvalidDevice;
    }
    return reg.device_id.get();
}
test getDeviceType {
    const t = try getDeviceType(qemu.virt_test.base);
    try std.testing.expect(t == .block);
}

pub fn Register(Config: type) type {
    _ = Config;

    const T = packed struct {
        magic: RegisterField(u32, .{ .offset = 0x00, .permission = .r }),
        version: RegisterField(u32, .{ .offset = 0x04, .permission = .r }),
        device_id: RegisterField(virtio.DeviceType, .{ .offset = 0x08, .permission = .r }),
        vendor_id: RegisterField(u32, .{ .offset = 0x0c, .permission = .r }),
        device_features: RegisterField(u32, .{ .offset = 0x10, .permission = .r }),
        device_features_sel: RegisterField(u32, .{ .offset = 0x14, .permission = .w, .padding = 64 }),
        driver_features: RegisterField(u32, .{ .offset = 0x20, .permission = .w }),
        driver_features_sel: RegisterField(u32, .{ .offset = 0x24, .permission = .w, .padding = 64 }),
        queue_sel: RegisterField(u32, .{ .offset = 0x30, .permission = .w }),
        queue_size_max: RegisterField(u32, .{ .offset = 0x34, .permission = .r }),
        queue_size: RegisterField(u32, .{ .offset = 0x38, .permission = .w, .padding = 64 }),
        queue_ready: RegisterField(u32, .{ .offset = 0x44, .permission = .rw, .padding = 64 }),
        queue_notify: RegisterField(u32, .{ .offset = 0x50, .permission = .w, .padding = 96 }),
        interrupt_status: RegisterField(u32, .{ .offset = 0x60, .permission = .r }),
        interrupt_ack: RegisterField(u32, .{ .offset = 0x64, .permission = .w, .padding = 64 }),
        status: RegisterField(virtio.DeviceStatus, .{ .offset = 0x70, .permission = .rw, .padding = 120 }),
        queue_desc_low: RegisterField(u32, .{ .offset = 0x80, .permission = .w }),
        queue_desc_high: RegisterField(u32, .{ .offset = 0x84, .permission = .w }),
    };

    const info = @typeInfo(T).@"struct";
    for (info.fields) |field| {
        if (field.name[0] == '_') continue;
        const expected_offset = field.type.offset;
        const actual_offset = @offsetOf(T, field.name);
        if (expected_offset != actual_offset) @compileError(std.fmt.comptimePrint(
            "expected offset of '{s}' is 0x{x}, but actual offset is 0x{x}",
            .{ field.name, expected_offset, actual_offset },
        ));
    }

    return T;
}


fn RegisterField(T: type, opts: struct {
    offset: usize,
    permission: enum { r, w, rw },
    padding: u16 = 0,
}) type {
    return packed struct {
        _inner: T,
        _: std.meta.Int(.unsigned, opts.padding) = 0,

        const offset = opts.offset;

        pub inline fn get(self: *const @This()) T {
            if (opts.permission == .w) @compileError("cannot read from write-only register");
            return std.mem.littleToNative(T, self._inner);
        }

        pub inline fn set(self: *@This(), value: T) void {
            if (opts.permission == .r) @compileError("cannot write to read-only register");
            self._inner = std.mem.nativeToLittle(T, value);
        }

        pub inline fn setBit(self: *@This(), bitflags: T) void {
            const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
            const lhs: Int = @bitCast(self.get());
            const rhs: Int = @bitCast(bitflags);
            self.set(lhs | rhs);
        }
    };
}
