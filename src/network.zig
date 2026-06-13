const std = @import("std");

const Be = @import("endian.zig").Big;

pub const MACAddress = extern struct {
    octets: [6]u8,

    pub const unspecified: MACAddress = .init(@splat(0x00));
    pub const broadcast: MACAddress = .init(@splat(0xff));

    pub fn init(address: [6]u8) MACAddress {
        return .{ .octets = address };
    }

    pub fn format(self: MACAddress, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
            self.octets[0], self.octets[1], self.octets[2],
            self.octets[3], self.octets[4], self.octets[5],
        });
    }
};

pub const EthernetHeader = extern struct {
    target_mac_address: MACAddress,
    source_mac_address: MACAddress,
    protocol: Be(EtherType),
};

pub const EtherType = enum(u16) {
    IPv4 = 0x800,
    ARP = 0x806,
    WoL = 0x842,
    IPv6 = 0x86dd,
    _,

    fn addressSizeHint(self: EtherType) ?u8 {
        return switch (self) {
            .IPv4 => 4,
            else => null,
        };
    }
};

pub const ARPHeader = extern struct {
    hardware: ARPHardwareType,
    protocol: Be(EtherType),
    hardware_address_size: u8,
    protocol_address_size: u8,
    operation: Be(ARPOperation),
};

pub fn StaticARPBody(hardware: HardwareType, protocol: EtherType) type {
    return extern struct {
        source_hardware_address: [hardware.addressSizeHint().?]u8,
        source_protocol_address: [protocol.addressSizeHint().?]u8,
        target_hardware_address: [hardware.addressSizeHint().?]u8,
        target_protocol_address: [protocol.addressSizeHint().?]u8,
    };
}

pub const ARPHardwareType = packed struct(u16) {
    _: u8 = 0,
    low: HardwareType,

    pub fn init(t: HardwareType) ARPHardwareType {
        return .{ .low = t };
    }
};

pub const HardwareType = enum(u8) {
    Ethernet = 1,
    IEEE_802 = 6,
    _,

    fn addressSizeHint(self: HardwareType) ?u8 {
        return switch (self) {
            .Ethernet => 6,
            .IEEE_802 => null,
            _ => null,
        };
    }
};

pub const ARPOperation = enum(u16) {
    request = 1,
    reply = 2,
    _,
};

pub fn buildARPRequest(
    our_mac: MACAddress,
    our_ip: IPv4Address,
    target_ip: IPv4Address,
) [@sizeOf(EthernetHeader) + @sizeOf(ARPHeader) + @sizeOf(StaticARPBody(.Ethernet, .IPv4))]u8 {
    const ethernet_header: EthernetHeader = .{
        .target_mac_address = .broadcast,
        .source_mac_address = our_mac,
        .protocol = .fromNative(.ARP),
    };
    const arp_header: ARPHeader = .{
        .hardware = .init(.Ethernet),
        .protocol = .fromNative(.IPv4),
        .hardware_address_size = HardwareType.addressSizeHint(.Ethernet).?,
        .protocol_address_size = EtherType.addressSizeHint(.IPv4).?,
        .operation = .fromNative(.request),
    };
    const arp_body: StaticARPBody(.Ethernet, .IPv4) = .{
        .source_hardware_address = our_mac.octets,
        .source_protocol_address = our_ip.octets,
        .target_hardware_address = MACAddress.unspecified.octets,
        .target_protocol_address = target_ip.octets,
    };
    return std.mem.toBytes(ethernet_header) ++ std.mem.toBytes(arp_header) ++ std.mem.toBytes(arp_body);
}

pub fn parseARPReply(frame: []const u8, our_ip: IPv4Address) ?MACAddress {
    var r: std.Io.Reader = .fixed(frame);

    const ethernet_header = r.takeStructPointer(EthernetHeader) catch return null;
    if (ethernet_header.protocol.toNative() != .ARP) return null;

    const arp_header = r.takeStructPointer(ARPHeader) catch return null;
    if (arp_header.operation.toNative() != .reply) return null;

    const arp_body = r.takeStructPointer(StaticARPBody(.Ethernet, .IPv4)) catch return null;
    if (!std.mem.eql(u8, &arp_body.target_protocol_address, &our_ip.octets)) return null;

    return .init(arp_body.source_hardware_address);
}

pub const IPv4Address = extern struct {
    octets: [4]u8,

    pub const unspecified: IPv4Address = .init(@splat(0));
    pub const broadcast: IPv4Address = .init(@splat(255));

    pub fn init(address: [4]u8) IPv4Address {
        return .{ .octets = address };
    }

    pub fn format(self: IPv4Address, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{}.{}.{}.{}", .{
            self.octets[0], self.octets[1], self.octets[2], self.octets[3],
        });
    }
};

/// https://www.iana.org/assignments/protocol-numbers/protocol-numbers.xhtml
pub const IPProtocolType = enum(u8) {
    ICMP = 1,
    TCP = 6,
    UDP = 17,
    ICMPv6 = 58,
    _,
};

/// https://datatracker.ietf.org/doc/html/rfc791
pub const IPv4Header = extern struct {
    meta: Metadata,
    type_of_service: u8,
    total_length: Be(u16),
    identification: Be(u16),
    fragment: Be(Fragment),
    time_to_live: u8,
    protocol: IPProtocolType,
    header_checksum: Be(u16),
    source_address: IPv4Address,
    destination_address: IPv4Address,

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

pub const ICMPType = enum(u8) {
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

pub const ICMPEchoHeader = extern struct {
    type: ICMPType,
    code: u8 = 0,
    checksum: Be(u16),
    identifier: Be(u16) = .fromNative(0),
    sequence: Be(u16) = .fromNative(0),
};

pub fn buildICMPEchoRequest(
    source_mac: MACAddress,
    target_mac: MACAddress,
    source_ip: IPv4Address,
    target_ip: IPv4Address,
    identifier: u16,
    sequence: u16,
) [@sizeOf(EthernetHeader) + @sizeOf(IPv4Header) + @sizeOf(ICMPEchoHeader)]u8 {
    const ethernet_header: EthernetHeader = .{
        .target_mac_address = target_mac,
        .source_mac_address = source_mac,
        .protocol = .fromNative(.IPv4),
    };

    var ip_header: IPv4Header = .{
        .meta = .{ .internet_header_length = 5 },
        .type_of_service = 0,
        .total_length = .fromNative(@sizeOf(IPv4Header) + @sizeOf(ICMPEchoHeader)),
        .identification = .fromNative(0),
        .fragment = .fromNative(.{ .dont_fragment = true }),
        .time_to_live = 64,
        .protocol = .ICMP,
        .header_checksum = .fromNative(0),
        .source_address = source_ip,
        .destination_address = target_ip,
    };
    const ip_checksum = computeChecksum(std.mem.asBytes(&ip_header));
    ip_header.header_checksum = .fromNative(ip_checksum);

    var icmp_header: ICMPEchoHeader = .{
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

pub fn parseICMPEchoReply(frame: []const u8, expected_id: u16, expected_seq: u16) bool {
    var r: std.Io.Reader = .fixed(frame);

    const ethernet_header = r.takeStructPointer(EthernetHeader) catch return false;
    if (ethernet_header.protocol.toNative() != .IPv4) return false;

    const ip_header = r.takeStructPointer(IPv4Header) catch return false;
    if (ip_header.protocol != .ICMP) return false;

    const icmp_header = r.takeStructPointer(ICMPEchoHeader) catch return false;
    if (icmp_header.type != .echo_reply) return false;
    if (icmp_header.identifier.toNative() != expected_id) return false;
    if (icmp_header.sequence.toNative() != expected_seq) return false;

    return true;
}

/// https://datatracker.ietf.org/doc/html/rfc0768
pub const UDPHeader = extern struct {
    source_port: Be(UDPPort),
    destination_port: Be(UDPPort),
    /// Length of the UDP segment
    length: Be(u16),
    checksum: Be(u16),
};

pub const PseudoUDPHeader = extern struct {
    source_address: IPv4Address,
    destination_address: IPv4Address,
    _: u8 = 0,
    protocol: IPProtocolType,
    /// Length of the TCP/UDP segment
    length: Be(u16),
};

pub const UDPPort = enum(u16) {
    BOOTP_server = 67,
    BOOTP_client = 68,
    _,

    pub const DHCP_server: UDPPort = .BOOTP_server;
    pub const DHCP_client: UDPPort = .BOOTP_client;
};

/// https://datatracker.ietf.org/doc/html/rfc2131
pub const DHCPMessage = extern struct {
    operation: BOOTPOperation,
    hardware: HardwareType,
    hardware_address_size: u8,
    hops: u8 = 0,
    transaction_id: u32,
    secs: Be(u16) = 0,
    flags: Be(Flags),
    client_ip_address: IPv4Address,
    your_ip_address: IPv4Address,
    server_ip_address: IPv4Address,
    gateway_ip_address: IPv4Address,
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

pub const BOOTPOperation = enum(u8) {
    request = 1,
    reply = 2,
};

/// https://datatracker.ietf.org/doc/html/rfc1497
pub const bootp_magic_cookie = std.mem.nativeToBig(u32, 0x63_82_53_63);

/// https://www.iana.org/assignments/bootp-dhcp-parameters/bootp-dhcp-parameters.xhtml
pub const DHCPOptionCode = enum(u8) {
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
pub const DHCPMessageType = enum(u8) {
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
