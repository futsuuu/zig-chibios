const std = @import("std");

const Be = @import("endian.zig").Big;

pub const MacAddress = extern struct {
    octets: [6]u8,

    pub const unspecified: MacAddress = .init(@splat(0x00));
    pub const broadcast: MacAddress = .init(@splat(0xff));

    pub fn init(address: [6]u8) MacAddress {
        return .{ .octets = address };
    }

    pub fn format(self: MacAddress, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
            self.octets[0], self.octets[1], self.octets[2],
            self.octets[3], self.octets[4], self.octets[5],
        });
    }
};

pub const EthernetHeader = extern struct {
    target_mac_address: MacAddress,
    source_mac_address: MacAddress,
    protocol: Be(EtherType),
};

pub const EtherType = enum(u16) {
    ipv4 = 0x800,
    arp = 0x806,
    wol = 0x842,
    ipv6 = 0x86dd,
    _,

    fn addressSizeHint(self: EtherType) ?u8 {
        return switch (self) {
            .ipv4 => 4,
            else => null,
        };
    }
};

pub const ArpHeader = extern struct {
    hardware: ArpHardwareType,
    protocol: Be(EtherType),
    hardware_address_size: u8,
    protocol_address_size: u8,
    operation: Be(ArpOperation),
};

pub fn StaticArpBody(hardware: HardwareType, protocol: EtherType) type {
    return extern struct {
        source_hardware_address: [hardware.addressSizeHint().?]u8,
        source_protocol_address: [protocol.addressSizeHint().?]u8,
        target_hardware_address: [hardware.addressSizeHint().?]u8,
        target_protocol_address: [protocol.addressSizeHint().?]u8,
    };
}

pub const ArpHardwareType = packed struct(u16) {
    _: u8 = 0,
    low: HardwareType,

    pub fn init(t: HardwareType) ArpHardwareType {
        return .{ .low = t };
    }
};

pub const HardwareType = enum(u8) {
    ethernet = 1,
    _,

    fn addressSizeHint(self: HardwareType) ?u8 {
        return switch (self) {
            .ethernet => 6,
            _ => null,
        };
    }
};

pub const ArpOperation = enum(u16) {
    request = 1,
    reply = 2,
    _,
};

pub fn buildArpRequest(
    our_mac: MacAddress,
    our_ip: Ipv4Address,
    target_ip: Ipv4Address,
) [@sizeOf(EthernetHeader) + @sizeOf(ArpHeader) + @sizeOf(StaticArpBody(.ethernet, .ipv4))]u8 {
    const ethernet_header: EthernetHeader = .{
        .target_mac_address = .broadcast,
        .source_mac_address = our_mac,
        .protocol = .fromNative(.arp),
    };
    const arp_header: ArpHeader = .{
        .hardware = .init(.ethernet),
        .protocol = .fromNative(.ipv4),
        .hardware_address_size = HardwareType.addressSizeHint(.ethernet).?,
        .protocol_address_size = EtherType.addressSizeHint(.ipv4).?,
        .operation = .fromNative(.request),
    };
    const arp_body: StaticArpBody(.ethernet, .ipv4) = .{
        .source_hardware_address = our_mac.octets,
        .source_protocol_address = our_ip.octets,
        .target_hardware_address = MacAddress.unspecified.octets,
        .target_protocol_address = target_ip.octets,
    };
    return std.mem.toBytes(ethernet_header) ++ std.mem.toBytes(arp_header) ++ std.mem.toBytes(arp_body);
}

pub fn parseArpReply(frame: []const u8, our_ip: Ipv4Address) ?MacAddress {
    var r: std.Io.Reader = .fixed(frame);

    const ethernet_header = r.takeStructPointer(EthernetHeader) catch return null;
    if (ethernet_header.protocol.toNative() != .arp) return null;

    const arp_header = r.takeStructPointer(ArpHeader) catch return null;
    if (arp_header.operation.toNative() != .reply) return null;

    const arp_body = r.takeStructPointer(StaticArpBody(.ethernet, .ipv4)) catch return null;
    if (!std.mem.eql(u8, &arp_body.target_protocol_address, &our_ip.octets)) return null;

    return .init(arp_body.source_hardware_address);
}

pub const Ipv4Address = extern struct {
    octets: [4]u8,

    pub const unspecified: Ipv4Address = .init(@splat(0));
    pub const broadcast: Ipv4Address = .init(@splat(255));

    pub fn init(address: [4]u8) Ipv4Address {
        return .{ .octets = address };
    }

    pub fn format(self: Ipv4Address, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{}.{}.{}.{}", .{
            self.octets[0], self.octets[1], self.octets[2], self.octets[3],
        });
    }
};

/// https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
pub const IpProtocolType = enum(u8) {
    icmp = 1,
    tcp = 6,
    udp = 17,
    icmpv6 = 58,
    _,
};

/// https://datatracker.ietf.org/doc/html/rfc791
pub const Ipv4Header = extern struct {
    meta: Metadata,
    type_of_service: u8,
    total_length: Be(u16),
    identification: Be(u16),
    fragment: Be(Fragment),
    time_to_live: u8,
    protocol: IpProtocolType,
    header_checksum: Be(u16),
    source_address: Ipv4Address,
    destination_address: Ipv4Address,

    pub const Metadata = packed struct(u8) {
        internet_header_length: u4,
        version: u4 = 4,
    };

    pub const Fragment = packed struct(u16) {
        /// Fragment offset in 8-byte units
        offset: u13 = 0,
        /// `false`: May Fragment, `true`: More Fragments
        more_fragments: bool = false,
        /// `false`: May Fragment, `true`: Don't Fragment
        dont_fragment: bool = false,
        /// Reserved (must be zero)
        _: u1 = 0,
    };

    test Fragment {
        const data: [2]u8 = .{ 0b0100_0000, 0b0000_1010 };
        try std.testing.expectEqual(
            Fragment{
                .offset = 10,
                .more_fragments = false,
                .dont_fragment = true,
            },
            std.mem.bytesToValue(Be(Fragment), &data).toNative(),
        );
    }
};

/// https://datatracker.ietf.org/doc/html/rfc1071
pub fn computeChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += @as(u16, data[i]) << 8 | data[i + 1];
    }
    if (i < data.len) {
        sum += @as(u16, data[i]) << 8;
    }
    while (sum >> 16 != 0) {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    return ~@as(u16, @truncate(sum));
}

test computeChecksum {
    try std.testing.expectEqual(
        ~@as(u16, 0xddf2),
        computeChecksum(&.{
            0x00, 0x01,
            0xf2, 0x03,
            0xf4, 0xf5,
            0xf6, 0xf7,
        }),
    );
}

pub const IcmpType = enum(u8) {
    destination_unreachable = 3,
    time_exceeded = 11,
    parameter_problem = 12,
    source_quench = 4,
    redirect = 5,
    echo = 8,
    echo_reply = 0,
    timestamp = 13,
    timestamp_reply = 14,
    information_request = 15,
    information_reply = 16,
};

pub const IcmpEchoHeader = extern struct {
    type: IcmpType,
    code: u8 = 0,
    checksum: Be(u16),
    identifier: Be(u16) = .fromNative(0),
    sequence: Be(u16) = .fromNative(0),
};

pub fn buildIcmpEchoRequest(
    source_mac: MacAddress,
    target_mac: MacAddress,
    source_ip: Ipv4Address,
    target_ip: Ipv4Address,
    identifier: u16,
    sequence: u16,
) [@sizeOf(EthernetHeader) + @sizeOf(Ipv4Header) + @sizeOf(IcmpEchoHeader)]u8 {
    const ethernet_header: EthernetHeader = .{
        .target_mac_address = target_mac,
        .source_mac_address = source_mac,
        .protocol = .fromNative(.ipv4),
    };

    var ip_header: Ipv4Header = .{
        .meta = .{ .internet_header_length = 5 },
        .type_of_service = 0,
        .total_length = .fromNative(@sizeOf(Ipv4Header) + @sizeOf(IcmpEchoHeader)),
        .identification = .fromNative(0),
        .fragment = .fromNative(.{ .dont_fragment = true }),
        .time_to_live = 64,
        .protocol = .icmp,
        .header_checksum = .fromNative(0),
        .source_address = source_ip,
        .destination_address = target_ip,
    };
    const ip_checksum = computeChecksum(std.mem.asBytes(&ip_header));
    ip_header.header_checksum = .fromNative(ip_checksum);

    var icmp_header: IcmpEchoHeader = .{
        .type = .echo,
        .code = 0,
        .checksum = .fromNative(0),
        .identifier = .fromNative(identifier),
        .sequence = .fromNative(sequence),
    };
    const icmp_checksum = computeChecksum(std.mem.asBytes(&icmp_header));
    icmp_header.checksum = .fromNative(icmp_checksum);

    return std.mem.toBytes(ethernet_header) ++ std.mem.toBytes(ip_header) ++ std.mem.toBytes(icmp_header);
}

pub fn parseIcmpEchoReply(frame: []const u8, expected_id: u16, expected_seq: u16) bool {
    var r: std.Io.Reader = .fixed(frame);

    const ethernet_header = r.takeStructPointer(EthernetHeader) catch return false;
    if (ethernet_header.protocol.toNative() != .ipv4) return false;

    const ip_header = r.takeStructPointer(Ipv4Header) catch return false;
    if (ip_header.protocol != .icmp) return false;

    const icmp_header = r.takeStructPointer(IcmpEchoHeader) catch return false;
    if (icmp_header.type != .echo_reply) return false;
    if (icmp_header.identifier.toNative() != expected_id) return false;
    if (icmp_header.sequence.toNative() != expected_seq) return false;

    return true;
}

/// https://datatracker.ietf.org/doc/html/rfc0768
pub const UdpHeader = extern struct {
    source_port: Be(UdpPort),
    destination_port: Be(UdpPort),
    /// Length of the UDP segment
    length: Be(u16),
    checksum: Be(u16),
};

pub const PseudoUdpHeader = extern struct {
    source_address: Ipv4Address,
    destination_address: Ipv4Address,
    _: u8 = 0,
    protocol: IpProtocolType,
    /// Length of the TCP/UDP segment
    length: Be(u16),
};

pub const UdpPort = enum(u16) {
    bootp_server = 67,
    bootp_client = 68,
    _,

    pub const dhcp_server: UdpPort = .bootp_server;
    pub const dhcp_client: UdpPort = .bootp_client;
};

/// https://datatracker.ietf.org/doc/html/rfc2131
pub const DhcpMessage = extern struct {
    operation: BootpOperation,
    hardware: HardwareType,
    hardware_address_size: u8,
    hops: u8 = 0,
    transaction_id: u32,
    secs: Be(u16) = .fromNative(0),
    flags: Be(Flags),
    client_ip_address: Ipv4Address,
    your_ip_address: Ipv4Address,
    server_ip_address: Ipv4Address,
    gateway_ip_address: Ipv4Address,
    client_hardware_address: [16]u8,
    server_host_name: [64]u8 = @splat(0),
    file: [128]u8 = @splat(0),
    // This field is defined in the 'options' field.
    magic_cookie: u32 = bootp_magic_cookie,

    pub const Flags = packed struct(u16) {
        _: u15 = 0,
        broadcast: bool,
    };
};

pub const BootpOperation = enum(u8) {
    request = 1,
    reply = 2,
};

/// https://datatracker.ietf.org/doc/html/rfc2132
pub const bootp_magic_cookie = std.mem.nativeToBig(u32, 0x63_82_53_63);

/// https://www.iana.org/assignments/bootp-dhcp-parameters/bootp-dhcp-parameters.xhtml
pub const DhcpOptionCode = enum(u8) {
    padding = 0,
    subnet_mask = 1,
    time_offset = 2,
    router = 3,
    time_server = 4,
    name_server = 5,
    domain_server = 6,
    log_server = 7,
    quotes_server = 8,
    lpr_server = 9,
    impress_server = 10,
    rlp_server = 11,
    hostname = 12,
    boot_file_size = 13,
    merit_dump_size = 14,
    domain_name = 15,
    swap_server = 16,
    root_path = 17,
    extension_file = 18,
    address_request = 50,
    dhcp_msg_type = 53,
    dhcp_server_id = 54,
    parameter_list = 55,
    client_id = 61,
    end = 255,
    _,
};

/// https://www.iana.org/assignments/bootp-dhcp-parameters/bootp-dhcp-parameters.xhtml
pub const DhcpMessageType = enum(u8) {
    discover = 1,
    offer = 2,
    request = 3,
    decline = 4,
    ack = 5,
    nak = 6,
    release = 7,
    inform = 8,
    _,
};
