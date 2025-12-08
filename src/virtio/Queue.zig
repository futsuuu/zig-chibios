const std = @import("std");

const endian = @import("../endian.zig");
const Le = endian.Little;

const Queue = @This();

index: u16,
desc_ring: []align(16) volatile Descriptor,
index_counter: usize = 0,
wrap_counter: bool = true,
/// Read-only
device_event: *align(4) const volatile EventSuppression,
/// Write-only
driver_event: *align(4) volatile EventSuppression,

pub fn init(a: std.mem.Allocator, index: u16, size: usize) std.mem.Allocator.Error!Queue {
    const desc = try a.alignedAlloc(Descriptor, .@"16", size);
    @memset(desc, .init);
    const supp = try a.alignedAlloc(EventSuppression, .@"4", 2);
    @memset(supp, .init);
    return .{
        .index = index,
        .desc_ring = desc,
        .device_event = &supp[0],
        .driver_event = &supp[1],
    };
}

pub fn getAddr(self: Queue, area: enum { desc, device, driver }) usize {
    switch (area) {
        .desc => return @intFromPtr(self.desc_ring.ptr),
        .device => return @intFromPtr(self.device_event),
        .driver => return @intFromPtr(self.driver_event),
    }
}

pub fn append(
    self: *Queue,
    comptime permission: enum { readonly, writable },
    bytes: switch (permission) {
        .readonly => []const u8,
        .writable => []volatile u8,
    },
    flags: Descriptor.Flags,
) *volatile Descriptor {
    const desc = &self.desc_ring[self.index_counter];
    desc.addr = .fromNative(@intCast(@intFromPtr(bytes.ptr)));
    desc.len = .fromNative(@intCast(bytes.len));
    desc.flags = .fromNative(flags.merge(.{ .write = permission == .writable }));
    self.index_counter += 1;
    if (self.index_counter == self.desc_ring.len) {
        std.debug.panic("handling of descriptor ring overflow is not yet implemented", .{});
        // self.index_counter = 0;
        // self.wrap_counter = !self.wrap_counter;
    }
    return desc;
}

pub fn markAsAvailable(self: Queue, desc: *volatile Descriptor) void {
    desc.flags = .fromNative(desc.flags.toNative().merge(.{
        .available = self.wrap_counter,
        .used = !self.wrap_counter,
    }));
}

pub fn isUsed(self: Queue, desc: *const volatile Descriptor) bool {
    _ = self;
    const flags = desc.flags.toNative();
    return flags.used == flags.available;
}

pub const Descriptor = packed struct(u128) {
    addr: Le(u64),
    len: Le(u32),
    id: Le(u16),
    flags: Le(Flags),

    const init = std.mem.zeroes(Descriptor);

    pub const Flags = packed struct(u16) {
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

        pub fn merge(self: Flags, other: Flags) Flags {
            return @bitCast(@as(u16, @bitCast(self)) | @as(u16, @bitCast(other)));
        }
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

    const init = std.mem.zeroes(EventSuppression);

    pub fn getEnabled(self: EventSuppression) ?union(enum) {
        all,
        only: struct { index: usize, wrap_counter: bool },
    } {
        return switch (self.flags.toNative().flags) {
            .enable => .all,
            .disable => null,
            .descriptor => .{ .only = b: {
                const desc = self.desc.toNative();
                break :b .{
                    .index = @intCast(desc.offset),
                    .wrap_counter = desc.wrap,
                };
            } },
        };
    }

    pub const Flags = enum(u2) {
        enable = 0,
        disable = 1,
        descriptor = 2,
    };
};
