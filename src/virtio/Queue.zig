const std = @import("std");

const endian = @import("../endian.zig");
const Le = endian.Little;

const Queue = @This();

desc_ring: []align(16) Descriptor,
/// Read-only
device: *align(4) const EventSuppression,
/// Write-only
driver: *align(4) EventSuppression,

pub fn init(a: std.mem.Allocator) Queue {
    _ = a;
}

pub const Descriptor = packed struct(u128) {
    addr: Le(u64),
    len: Le(u32),
    id: Le(u16),
    flags: Le(Flags),

    const Flags = packed struct(u16) {
        // 1 << 0
        next: bool = false,
        // 1 << 1
        write: bool = false,
        // 1 << 2
        indirect: bool = false,
        _0: u4 = 0,
        // 1 << 7
        available: bool = false,
        _1: u7 = 0,
        // 1 << 15
        used: bool = false,
    };
};

pub const EventSuppression = packed struct(u32) {
    desc: Le(packed struct(u16) {
        offset: u15,
        wrap: bool,
    }),
    flags: Le(packed struct(u16) {
        flags: Flags,
        _: u14 = 0,
    }),

    const Flags = enum(u2) {
        enable = 0,
        disable = 1,
        descriptor = 2,
        _, // 3 is reserved
    };
};
