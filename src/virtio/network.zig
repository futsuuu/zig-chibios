const std = @import("std");
const log = std.log.scoped(.virtio_net);

const Le = @import("../endian.zig").Little;
const PagedBumpAllocator = @import("../PagedBumpAllocator.zig");
const network = @import("../network.zig");
const virtio = @import("../virtio.zig");

pub const Driver = struct {
    bump: PagedBumpAllocator,
    receiveq1: virtio.Queue,
    transmitq1: virtio.Queue,
    register: *virtio.mmio.Register,
    features: virtio.feature.Set(Feature),
    receive_bufs: [][]u8,

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
        features.unset(.{ .device = .hash_report });
        features.unset(.{ .device = .multiqueue });
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
            var chain = receiveq1.append(.writable, buf);
            _ = chain.finishWithoutNotify();
        }

        register.status.writeBit(.{ .driver_ok = true });
        receiveq1.notify();
        return .{
            .bump = bump,
            .receiveq1 = receiveq1,
            .transmitq1 = transmitq1,
            .register = register,
            .features = features,
            .receive_bufs = receive_bufs,
        };
    }

    pub fn deinit(self: Driver) void {
        self.register.status.write(.reset);
        while (self.register.status.read() != virtio.DeviceStatus.reset) {
            std.atomic.spinLoopHint();
        }
        self.bump.deinit();
    }

    pub fn macAddress(self: *Driver) ?network.MacAddress {
        if (self.features.has(.{ .device = .mac_address })) {
            const config = self.register.config(Config);
            return config.mac_address;
        }
        return null;
    }

    pub fn sendFrame(self: *Driver, data: []const u8) void {
        const header: PacketHeader = .{
            .flags = .{ .needs_checksum = false, .data_valid = false },
            .gso_type = .none,
            .header_len = .fromNative(0),
            .gso_size = .fromNative(0),
            .checksum_start = .fromNative(0),
            .checksum_offset = .fromNative(0),
            .num_buffers = .fromNative(0),
            .hash_value = undefined,
            .hash_report = undefined,
        };
        var chain = self.transmitq1.append(.readonly, header.asBytes(&self.features));
        chain.next(.readonly, data);
        _ = chain.finish();
        _ = self.transmitq1.waitUsed();
    }

    pub fn receiveFrame(self: *Driver, out_buf: []u8) ?usize {
        const desc = self.receiveq1.waitUsed();
        const addr = desc.addr.toNative();
        const buf = for (self.receive_bufs) |b| {
            if (@intFromPtr(b.ptr) == addr) break b;
        } else unreachable;
        const packet_len = desc.len.toNative();
        const header_len = PacketHeader.size(&self.features);
        if (packet_len <= header_len) return null;
        const frame_len = @min(packet_len - header_len, out_buf.len);
        @memcpy(out_buf[0..frame_len], buf[header_len..packet_len]);
        var chain = self.receiveq1.append(.writable, buf);
        _ = chain.finish();
        return frame_len;
    }
};

pub const Config = extern struct {
    mac_address: network.MacAddress,
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
    mac_address = 5,
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
    /// Only if VIRTIO_NET_F_HASH_REPORT negotiated
    hash_value: Le(u32),
    /// Only if VIRTIO_NET_F_HASH_REPORT negotiated
    hash_report: Le(u16),
    /// Only if VIRTIO_NET_F_HASH_REPORT negotiated
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

    fn size(features: *const virtio.feature.Set(Feature)) usize {
        return if (features.has(.{ .device = .hash_report }))
            @sizeOf(PacketHeader)
        else
            @offsetOf(PacketHeader, "hash_value");
    }

    fn asBytes(self: *const PacketHeader, features: *const virtio.feature.Set(Feature)) []const u8 {
        return std.mem.asBytes(self)[0..size(features)];
    }
};
