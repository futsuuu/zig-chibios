const std = @import("std");
const log = std.log.scoped(.virtio_net);

const Le = @import("../endian.zig").Little;
const PagedBumpAllocator = @import("../PagedBumpAllocator.zig");
const virtio = @import("../virtio.zig");

pub const Driver = struct {
    bump: PagedBumpAllocator,
    receiveq1: virtio.Queue,
    transmitq1: virtio.Queue,
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
        try features.require(.{ .device = .merge_receive_buf });
        features.unset(.{ .reserved = .notification_data });
        features.unset(.{ .reserved = .notification_config_data });
        features.unset(.{ .device = .multiqueue });
        features.unset(.{ .device = .mac_address });
        log.debug("driver features: {f}", .{features});
        try register.writeDriverFeatures(Feature, features);

        var bump: PagedBumpAllocator = .init;
        errdefer bump.deinit();

        var receiveq1 = try virtio.Queue.init(bump.allocator(), 0, register) orelse {
            log.err("receiveq1 unavailable", .{});
            return error.InvalidDevice;
        };
        const transmitq1 = try virtio.Queue.init(bump.allocator(), 1, register) orelse {
            log.err("transmitq1 unavailable", .{});
            return error.InvalidDevice;
        };
        const receive_bufs = try bump.allocator().alloc([]u8, receiveq1.desc_ring.len);
        for (0..receiveq1.desc_ring.len) |i| {
            const buf = try bump.allocator().alloc(u8, 128);
            receive_bufs[i] = buf;
            const desc = receiveq1.append(.writable, buf, .{});
            receiveq1.markAsAvailable(desc);
        }

        register.status.writeBit(.{ .driver_ok = true });
        return .{
            .bump = bump,
            .receiveq1 = receiveq1,
            .transmitq1 = transmitq1,
            .register = register,
            .features = features,
        };
    }

    pub fn deinit(self: Driver) void {
        self.register.status.write(.reset);
        while (self.register.status.read() != virtio.DeviceStatus.reset) {
            std.atomic.spinLoopHint();
        }
        self.bump.deinit();
    }
};

pub const Config = extern struct {
    mac_address: [6]u8,
    status: Le(Status),
    max_virtqueue_pairs: Le(u16),
    mtu: Le(u16),
    speed: Le(u32),
    duplex: u8,
    rss_max_key_size: u8,
    rss_max_indirection_table_len: Le(u16),
    supported_hash_types: Le(u32),
    supported_tunnel_types: Le(u32),
};

pub const Status = enum(u16) {
    link_up = 1,
    announce = 2,
};

pub const Feature = enum(u32) {
    checksum = 0,
    guest_checksum = 1,
    control_guest_offloads = 2,
    mtu = 3,
    mac_address = 4,
    guest_tso4 = 7,
    guest_tso6 = 8,
    guest_ecn = 9,
    guest_ufo = 10,
    host_tso4 = 11,
    host_tso6 = 12,
    host_ecn = 13,
    host_ufo = 14,
    merge_receive_buf = 15,
    status = 16,
    control_virtqueue = 17,
    control_rx = 18,
    control_vlan = 19,
    control_rx_extra = 20,
    guest_announce = 21,
    multiqueue = 22,
    control_mac_address = 23,
    hash_tunnel = 51,
    virtqueue_notification_coalescing = 52,
    notification_coalescing = 53,
    guest_uso4 = 54,
    guest_uso6 = 55,
    host_uso = 56,
    hash_report = 57,
    guest_header_len = 59,
    rss = 60,
    rsc_ext = 61,
    standby = 62,
    speed_duplex = 63,
};

pub const PacketHeader = extern struct {
    flags: Flag,
    gso_type: GsoType,
    header_len: Le(u16),
    gso_size: Le(u16),
    checksum_start: Le(u16),
    checksum_offset: Le(u16),
    num_buffers: Le(u16),
    hash_value: Le(u32),
    hash_report: Le(u16),
    _: u16 = 0,

    pub const Flag = packed struct(u8) {
        needs_checksum: bool = false,
        data_valid: bool = false,
        rsc_info: bool = false,
        _: u5 = 0,
    };

    pub const GsoType = enum(u8) {
        none = 0,
        tcp_v4 = 1,
        udp = 3,
        tcp_v6 = 4,
        udp_l4 = 5,
        ecn = 0x80,
    };
};
