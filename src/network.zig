const std = @import("std");

const Be = @import("endian.zig").Big;

pub const MACAddress = extern struct {
    bytes: [6]u8,

    pub const broadcast: MACAddress = .init(@splat(0xff));

    pub fn init(address: [6]u8) MACAddress {
        return .{ .bytes = address };
    }

    pub fn format(self: MACAddress, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
            self.bytes[0], self.bytes[1], self.bytes[2],
            self.bytes[3], self.bytes[4], self.bytes[5],
        });
    }
};

pub const IPv4Address = extern struct {
    bytes: [4]u8,

    pub fn init(address: [4]u8) IPv4Address {
        return .{ .bytes = address };
    }

    pub fn format(self: IPv4Address, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{}.{}.{}.{}", .{
            self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3],
        });
    }
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
        .source_hardware_address = our_mac.bytes,
        .source_protocol_address = our_ip.bytes,
        .target_hardware_address = @splat(0),
        .target_protocol_address = target_ip.bytes,
    };
    return std.mem.toBytes(ethernet_header) ++ std.mem.toBytes(arp_header) ++ std.mem.toBytes(arp_body);
}

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
    _,

    fn addressSizeHint(self: ARPHardwareType) ?u8 {
        return switch (self) {
            .Ethernet => 6,
            _ => null,
        };
    }
};

pub const ARPOperation = enum(u16) {
    request = 1,
    reply = 2,
    _,
};

pub fn parseARPReply(frame: []const u8, our_ip: IPv4Address) ?MACAddress {
    const body_size = @sizeOf(StaticARPBody(.Ethernet, .IPv4));
    const offset = @sizeOf(EthernetHeader) + @sizeOf(ARPHeader);
    if (frame.len < offset + body_size) return null;

    const ethernet_header = std.mem.bytesAsValue(EthernetHeader, frame[0..@sizeOf(EthernetHeader)]);
    if (ethernet_header.protocol.toNative() != .ARP) return null;

    const arp_header = std.mem.bytesAsValue(ARPHeader, frame[@sizeOf(EthernetHeader)..][0..@sizeOf(ARPHeader)]);
    if (arp_header.operation.toNative() != .reply) return null;

    const arp_body = std.mem.bytesAsValue(StaticARPBody(.Ethernet, .IPv4), frame[offset..][0..body_size]);
    if (!std.mem.eql(u8, &arp_body.target_protocol_address, &our_ip.bytes)) return null;

    return .init(arp_body.source_hardware_address);
}
