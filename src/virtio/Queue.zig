const std = @import("std");

const Le = @import("../endian.zig").Little;
const virtio = @import("../virtio.zig");

const Queue = @This();

index: u16,
desc_ring: []align(16) volatile Descriptor,
index_counter: usize = 0,
wrap_counter: bool = true,
/// Read-only
device_event: *align(4) const volatile EventSuppression,
/// Write-only
driver_event: *align(4) volatile EventSuppression,

register: *virtio.mmio.Register,

pub fn init(arena: std.mem.Allocator, index: u16, register: *virtio.mmio.Register) virtio.InitError!?Queue {
    const queue_register = try register.selectQueue(index) orelse return null;
    const desc_ring = try arena.alignedAlloc(Descriptor, .@"16", queue_register.size_max.read());
    comptime std.debug.assert(4 == @alignOf(EventSuppression));
    const device_event = try arena.create(EventSuppression);
    const driver_event = try arena.create(EventSuppression);
    @memset(desc_ring, .init);
    device_event.* = .init;
    driver_event.* = .init;
    queue_register.size.write(@intCast(desc_ring.len));
    queue_register.setAddr(.desc, @intFromPtr(desc_ring.ptr));
    queue_register.setAddr(.driver, @intFromPtr(device_event));
    queue_register.setAddr(.device, @intFromPtr(driver_event));
    queue_register.ready.write(1);
    return .{
        .index = index,
        .desc_ring = desc_ring,
        .device_event = device_event,
        .driver_event = driver_event,
        .register = register,
    };
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
    desc.addr = .fromNative(@intFromPtr(bytes.ptr));
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
