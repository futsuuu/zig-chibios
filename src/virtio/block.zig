const endian = @import("../endian.zig");
const Le = endian.Little;
const virtio = @import("../virtio.zig");

pub const Config = packed struct {
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
