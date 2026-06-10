const std = @import("std");
const log = std.log.scoped(.virtio_blk);

const Le = @import("../endian.zig").Little;
const PagedBumpAllocator = @import("../PagedBumpAllocator.zig");
const virtio = @import("../virtio.zig");

pub const Driver = struct {
    bump: PagedBumpAllocator,
    requestq1: virtio.Queue,
    register: *virtio.mmio.Register,
    features: virtio.feature.Set(Feature),

    pub fn init(register_header: *const virtio.mmio.RegisterHeader) virtio.InitError!Driver {
        const register: *virtio.mmio.Register = .init(register_header);
        register.status.write(.reset);
        register.status.writeBit(.{ .acknowledge = true });
        errdefer register.status.writeBit(.{ .failed = true });
        register.status.writeBit(.{ .driver = true });

        var features = register.readDeviceFeatures(Feature);
        log.debug("device features: {f}", .{features});
        try features.require(.{ .reserved = .version_1 });
        try features.require(.{ .reserved = .ring_packed });
        features.unset(.{ .reserved = .notification_data });
        features.unset(.{ .reserved = .notification_config_data });
        features.unset(.{ .device = .flush });
        features.unset(.{ .device = .zoned });
        log.debug("driver features: {f}", .{features});
        try register.writeDriverFeatures(Feature, features);

        var bump: PagedBumpAllocator = .init;
        errdefer bump.deinit();

        const requestq1 = try virtio.Queue.init(bump.allocator(), 0, register) orelse {
            log.err("requestq1 unavailable", .{});
            return error.InvalidDevice;
        };
        register.status.writeBit(.{ .driver_ok = true });

        return .{
            .bump = bump,
            .requestq1 = requestq1,
            .register = register,
            .features = features,
        };
    }

    pub fn deinit(self: Driver) void {
        defer self.bump.deinit();
        self.register.status.write(.reset);
        while (self.register.status.read() != virtio.DeviceStatus.reset) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn request(
        self: *Driver,
        comptime t: enum { read, write },
        buf: switch (t) {
            .read => []u8,
            .write => []const u8,
        },
        sector: u64,
    ) RequestStatus.Error!void {
        const header: RequestHeader = switch (t) {
            .read => .init(.read, sector),
            .write => .init(.write, sector),
        };
        var chain = self.requestq1.append(.readonly, std.mem.asBytes(&header));
        switch (t) {
            .read => chain.next(.writable, buf),
            .write => chain.next(.readonly, buf),
        }
        var status: RequestStatus = undefined;
        chain.next(.writable, std.mem.asBytes(&status));
        const id = chain.finish();
        const ret = self.requestq1.waitUsed();
        std.debug.assert(ret.id.toNative() == id);
        return status.ensureOk();
    }
};

pub const Config = extern struct {
    capacity: Le(u64),
};

pub const Feature = enum(u32) {
    size_max = 1,
    seg_max = 2,
    geometry = 4,
    readonly = 5,
    block_size = 6,
    flush = 9,
    topology = 10,
    config_wce = 11,
    multiqueue = 12,
    discard = 13,
    write_zeroes = 14,
    lifetime = 15,
    secure_erase = 16,
    zoned = 17,
};

pub const RequestHeader = packed struct {
    type: Le(Type),
    _: u32 = 0,
    sector: Le(u64),

    pub fn init(t: Type, sector: u64) RequestHeader {
        return .{
            .type = .fromNative(t),
            .sector = .fromNative(sector),
        };
    }

    pub const Type = enum(u32) {
        in = 0,
        out = 1,
        flush = 4,
        get_id = 8,
        get_lifetime = 10,
        discard = 11,
        write_zeroes = 13,
        secure_erase = 14,

        zone_append = 15,
        zone_report = 16,
        zone_open = 17,
        zone_close = 20,
        zone_finish = 22,
        zone_reset = 24,
        zone_reset_all = 25,

        pub const read: Type = .in;
        pub const write: Type = .out;
    };
};

pub const RequestStatus = enum(u8) {
    ok = 0,
    io_error = 1,
    unsupported = 2,

    zone_invalid_cmd = 3,
    zone_unaligned_wp = 4,
    zone_open_resource = 5,
    zone_active_resource = 6,

    pub const Error = error{
        Io,
        Unsupported,
        ZoneInvalidCmd,
        ZoneUnalignedWp,
        ZoneOpenResource,
        ZoneActiveResource,
    };

    pub fn ensureOk(self: RequestStatus) Error!void {
        return switch (self) {
            .ok => {},
            .io_error => Error.Io,
            .unsupported => Error.Unsupported,
            .zone_invalid_cmd => Error.ZoneInvalidCmd,
            .zone_unaligned_wp => Error.ZoneUnalignedWp,
            .zone_open_resource => Error.ZoneOpenResource,
            .zone_active_resource => Error.ZoneActiveResource,
        };
    }
};
