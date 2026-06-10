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
    hardware: Be(ARPHardwareType),
    protocol: Be(EtherType),
    hardware_address_size: u8,
    protocol_address_size: u8,
    operation: Be(ARPOperation),
};

pub fn StaticARPBody(hardware: ARPHardwareType, protocol: EtherType) type {
    return extern struct {
        source_hardware_address: [hardware.addressSizeHint().?]u8,
        source_protocol_address: [protocol.addressSizeHint().?]u8,
        target_hardware_address: [hardware.addressSizeHint().?]u8,
        target_protocol_address: [protocol.addressSizeHint().?]u8,
    };
}

pub const ARPHardwareType = enum(u16) {
    Ethernet = 1,
    IEEE_802 = 6,
    _,

    fn addressSizeHint(self: ARPHardwareType) ?u8 {
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
        .hardware = .fromNative(.Ethernet),
        .protocol = .fromNative(.IPv4),
        .hardware_address_size = ARPHardwareType.addressSizeHint(.Ethernet).?,
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
