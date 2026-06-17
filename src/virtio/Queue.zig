const std = @import("std");
const log = std.log.scoped(.virtio_queue);

const arch = @import("arch");
const Le = @import("shared").Le;

const virtio = @import("root.zig");

const Queue = @This();

index: u16,
desc_ring: []align(16) volatile Descriptor,
avail_counter: u64 = 0,
used_counter: u64 = 0,
/// Read-only
device_event: *align(4) const volatile EventSuppression,
/// Write-only
driver_event: *align(4) volatile EventSuppression,

buffer_id_pool: BufferIdPool,
chain_length_map: []u15,

register: *virtio.mmio.Register,

const DescriptorIndex = struct {
    wrap: bool,
    index: u15,
};

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
        .buffer_id_pool = try .init(arena, desc_ring.len),
        .chain_length_map = try arena.alloc(u15, desc_ring.len),
        .register = register,
    };
}

pub fn waitUsed(self: *Queue) *const volatile Descriptor {
    const desc = &self.desc_ring[@intCast(self.used_counter % self.desc_ring.len)];
    while (!self.isUsed(desc)) {
        std.atomic.spinLoopHint();
    }
    const id: u15 = @intCast(desc.id.toNative());
    self.used_counter += self.chain_length_map[id];
    self.buffer_id_pool.release(id);
    return desc;
}

pub fn append(
    self: *Queue,
    comptime permission: enum { readonly, writable },
    bytes: switch (permission) {
        .readonly => []const u8,
        .writable => []volatile u8,
    },
) DescriptorChain {
    return .{
        .queue = self,
        .first_dest = self.nextAvailable(),
        .first = .{
            .addr = @intFromPtr(bytes.ptr),
            .len = @intCast(bytes.len),
            .writable = permission == .writable,
        },
    };
}

fn nextAvailable(self: *Queue) DescriptorIndex {
    defer self.avail_counter += 1;
    const div = self.avail_counter / self.desc_ring.len;
    const rem = self.avail_counter % self.desc_ring.len;
    return .{
        .index = @intCast(rem),
        .wrap = div % 2 == 0,
    };
}

pub fn notify(self: *Queue) void {
    arch.barrier.full();
    if (self.device_event.getEnabled()) |_| {
        self.register.queue_notify.write(.{ .vq_index = self.index, .data = undefined });
    }
}

const DescriptorChain = struct {
    queue: *Queue,
    len: u15 = 1,
    first_dest: DescriptorIndex,
    first: BufferedDescriptor,
    last: ?BufferedDescriptor = null,

    const BufferedDescriptor = struct {
        addr: u64,
        len: u32,
        writable: bool,

        fn write(
            self: BufferedDescriptor,
            queue: *Queue,
            dest_index: DescriptorIndex,
            id: ?u15,
        ) void {
            queue.desc_ring[dest_index.index] = .{
                .addr = .fromNative(self.addr),
                .len = .fromNative(self.len),
                .id = if (id) |i| .fromNative(i) else undefined,
                .flags = .fromNative(.{
                    .next = id == null,
                    .write = self.writable,
                    .available = dest_index.wrap,
                    .used = !dest_index.wrap,
                }),
            };
        }
    };

    pub fn next(
        self: *DescriptorChain,
        comptime permission: enum { readonly, writable },
        bytes: switch (permission) {
            .readonly => []const u8,
            .writable => []volatile u8,
        },
    ) void {
        self.len += 1;
        if (self.last) |prev| {
            prev.write(self.queue, self.queue.nextAvailable(), null);
        }
        self.last = .{
            .addr = @intFromPtr(bytes.ptr),
            .len = @intCast(bytes.len),
            .writable = permission == .writable,
        };
    }

    pub fn finish(self: *DescriptorChain) u15 {
        defer self.queue.notify();
        return self.finishWithoutNotify();
    }

    pub fn finishWithoutNotify(self: *DescriptorChain) u15 {
        const id = self.queue.buffer_id_pool.acquire();
        if (self.last) |last| {
            last.write(self.queue, self.queue.nextAvailable(), id);
        }
        self.queue.chain_length_map[id] = self.len;
        arch.barrier.write();
        self.first.write(self.queue, self.first_dest, if (self.last != null) null else id);
        return id;
    }
};

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
        only: struct { index: u15, wrap_counter: bool },
    } {
        return switch (self.flags.toNative().flags) {
            .enable => .all,
            .disable => null,
            .descriptor => .{ .only = b: {
                const desc = self.desc.toNative();
                break :b .{
                    .index = desc.offset,
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

const BufferIdPool = struct {
    free_set: std.DynamicBitSetUnmanaged,

    fn init(allocator: std.mem.Allocator, desc_ring_len: usize) std.mem.Allocator.Error!BufferIdPool {
        if (std.math.maxInt(u15) + 1 < desc_ring_len) {
            std.debug.panic("too large descriptor ring size: {}", .{desc_ring_len});
        }
        return .{
            .free_set = try .initFull(allocator, desc_ring_len),
        };
    }

    fn deinit(self: BufferIdPool, allocator: std.mem.Allocator) void {
        self.free_set.deinit(allocator);
    }

    fn acquire(self: *BufferIdPool) u15 {
        const id = self.free_set.findFirstSet() orelse {
            std.debug.panic("Buffer ID leaked", .{});
        };
        self.free_set.unset(id);
        return @intCast(id);
    }

    fn release(self: *BufferIdPool, id: u15) void {
        if (self.free_set.isSet(id)) {
            std.debug.panic("invalid Buffer ID: {}", .{id});
        }
        self.free_set.set(id);
    }
};
