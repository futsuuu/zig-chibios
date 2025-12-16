const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.buddy_allocator);

pub const Config = struct {
    page_size: comptime_int = std.heap.pageSize(),
    max_order: comptime_int = 11,

    fn assertValid(self: Config) void {
        assert(0 < self.page_size);
        assert(std.math.isPowerOfTwo(self.page_size));
    }
};

pub fn BuddyAllocator(config: Config) type {
    config.assertValid();

    return struct {
        const Self = @This();

        pages: [][config.page_size]u8,
        tree: BlockTree(config.max_order),

        pub fn init(bytes: []u8) Allocator.Error!Self {
            const mem: []u8 = std.mem.alignInBytes(bytes, config.page_size) orelse &.{};
            const pages_ptr: [*][config.page_size]u8 = @ptrCast(mem.ptr);
            const pages = pages_ptr[0 .. mem.len / config.page_size];
            var fba: std.heap.FixedBufferAllocator = .init(bytes);
            var self: Self = .{
                .pages = pages,
                .tree = try .init(fba.allocator(), pages.len),
            };
            if (self.pageRangeFromBytes(fba.buffer[0..fba.end_index])) |range| {
                self.tree.markPageAs(.used, range.start, range.end);
            }
            return self;
        }

        fn pageRangeFromBytes(self: Self, bytes: []const u8) ?struct { start: usize, end: usize } {
            const bytes_start = @intFromPtr(bytes.ptr);
            const bytes_end = @intFromPtr(bytes[bytes.len..].ptr);
            const pages_start = @intFromPtr(self.pages.ptr);
            const pages_end = @intFromPtr(self.pages[self.pages.len..].ptr);
            if (bytes_end <= pages_start or pages_end <= bytes_start) return null;
            const alignment = std.mem.Alignment.fromByteUnits(config.page_size);
            const start = alignment.backward(@max(bytes_start, pages_start));
            const end = alignment.forward(@min(bytes_end, pages_end));
            return .{
                .start = (start - pages_start) / config.page_size,
                .end = (end - pages_start) / config.page_size,
            };
        }

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        pub const vtable: Allocator.VTable = .{
            .alloc = rawAlloc,
            .resize = rawResize,
            .remap = rawRemap,
            .free = rawFree,
        };

        fn rawAlloc(
            ctx: *anyopaque,
            len: usize,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) ?[*]u8 {
            _ = ret_addr;
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (config.page_size < alignment.toByteUnits()) {
                panic("allocating with an alignment larger than the page size is not implemented", .{});
            }
            const num_pages = (len + config.page_size - 1) / config.page_size;
            const page_index = self.tree.allocBlock(num_pages) orelse return null;
            return @ptrCast(self.pages[page_index..]);
        }

        fn rawFree(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            ret_addr: usize,
        ) void {
            _ = alignment;
            _ = ret_addr;
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.pageRangeFromBytes(memory)) |range| {
                self.tree.freeBlock(range.start, range.end - range.start);
            }
        }

        fn rawResize(
            ctx: *anyopaque,
            memory: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            _ = ctx;
            _ = memory;
            _ = new_len;
            _ = alignment;
            _ = ret_addr;
            return false;
        }

        fn rawRemap(
            ctx: *anyopaque,
            old: []u8,
            alignment: std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            const new = rawAlloc(ctx, new_len, alignment, ret_addr) orelse return null;
            @memcpy(new, old[0..@min(old.len, new_len)]);
            rawFree(ctx, old, alignment, ret_addr);
            return new;
        }
    };
}

test BuddyAllocator {
    const free_ram = @extern([*]u8, .{ .name = "__free_ram" });
    const free_ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });
    const buf = free_ram[0 .. free_ram_end - free_ram];
    var buddy_allocator: BuddyAllocator(.{}) = try .init(buf);
    const allocator = buddy_allocator.allocator();
    try std.heap.testAllocator(allocator);
    try std.heap.testAllocatorAligned(allocator);
    try std.heap.testAllocatorLargeAlignment(allocator);
    try std.heap.testAllocatorAlignedShrink(allocator);
}

const Order = struct {
    const Int = std.math.Log2Int(usize);

    fn fromNumberOfPages(num_pages: usize) Int {
        if (num_pages == 0) {
            panic("number of pages must be larger than zero", .{});
        }
        return @intCast(std.math.log2_int_ceil(usize, num_pages));
    }

    fn blockSize(order: Int) usize {
        return @as(usize, 1) << order;
    }
};

fn BlockTree(max_order: Order.Int) type {
    return struct {
        const Self = @This();

        inner: [@as(usize, @intCast(max_order)) + 1]Blocks,

        fn init(allocator: Allocator, num_pages: usize) Allocator.Error!Self {
            const virt_num_pages = if (0 < num_pages)
                std.math.ceilPowerOfTwoAssert(usize, num_pages)
            else
                0;
            var self: Self = .{ .inner = undefined };
            for (0..self.inner.len) |order| {
                self.inner[order] = try .init(
                    allocator,
                    virt_num_pages / Order.blockSize(@intCast(order)),
                );
            }
            self.markPageAs(.used, num_pages, virt_num_pages);
            return self;
        }

        test "init() should succeed even if page count is zero" {
            var buf: [0]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            const self: Self = try .init(fba.allocator(), 0);
            try expectEqual(@as(usize, 0), self.inner[0].capacity());
        }

        test "init() should make specified number of pages available" {
            var buf: [1024]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            var self: Self = undefined;

            self = try init(fba.allocator(), 7);
            try expectEqual(@as(usize, 7), self.inner[0].count(.available));
            fba.reset();
            self = try init(fba.allocator(), 1025);
            try expectEqual(@as(usize, 1025), self.inner[0].count(.available));
            fba.reset();
            try std.testing.expect(error.OutOfMemory == init(fba.allocator(), 8 * 1024));
        }

        fn allocBlock(self: *Self, num_pages: usize) ?usize {
            const order = Order.fromNumberOfPages(num_pages);
            const page_index = self.findAvailableBlock(order) orelse return null;
            self.markPageAs(.used, page_index, page_index + Order.blockSize(order));
            return page_index;
        }

        fn freeBlock(self: *Self, page_index: usize, num_pages: usize) void {
            const order = Order.fromNumberOfPages(num_pages);
            self.markPageAs(.available, page_index, page_index + Order.blockSize(order));
        }

        /// Returns a page index.
        fn findAvailableBlock(self: Self, order: Order.Int) ?usize {
            if (max_order < order) @panic("unimplemented");
            const blocks = self.inner[@intCast(order)];
            return if (blocks.findAvailable()) |block_index|
                Order.blockSize(order) * block_index
            else
                null;
        }

        fn markPageAs(
            self: *Self,
            comptime state: BlockState,
            /// Inclusive
            page_start: usize,
            /// Exclusive
            page_end: usize,
        ) void {
            var range = Blocks.Range.init(page_start, page_end) orelse return;
            var order: Order.Int = 0;
            while (order <= max_order) : (order += 1) {
                const blocks = &self.inner[@intCast(order)];
                blocks.markAs(state, range);
                range = blocks.parentRange(state, range) orelse break;
            }
        }

        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll("{ ");
            for (self.inner, 0..) |bitset, order| {
                if (order != 0) try writer.writeAll(", ");
                if (bitset.capacity() == 0) {
                    try writer.writeAll("0");
                } else {
                    try writer.print("{}/{}", .{ bitset.count(.used), bitset.capacity() });
                }
            }
            try writer.writeAll(" }");
        }
    };
}

test BlockTree {
    _ = BlockTree(0);
    _ = BlockTree(11);
    _ = BlockTree(31);

    var buf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var tree: BlockTree(4) = try .init(fba.allocator(), 8);
    // ........
    try expectEqual(@as(?usize, 0), tree.allocBlock(3));
    // ###=....
    try expectEqual(@as(?usize, 4), tree.allocBlock(1));
    // ###=#...
    try expectEqual(@as(?usize, 6), tree.allocBlock(2));
    // ###=#.##
    tree.freeBlock(4, 1);
    // ###=..##
    try expectEqual(@as(?usize, null), tree.allocBlock(3));
    tree.freeBlock(0, 3);
    // ......##
    try expectEqual(@as(?usize, 0), tree.allocBlock(4));
    // ####..##
}

const BlockState = enum {
    used,
    available,
    fn toBool(self: @This()) bool {
        return self == .available;
    }
    fn fromBool(val: bool) @This() {
        return if (val) .available else .used;
    }
};

const Blocks = struct {
    bitset: std.DynamicBitSetUnmanaged,

    const Range = struct {
        start: usize,
        end: usize,
        fn init(start: usize, end: usize) ?Range {
            if (end < start) panic("invalid block range: {}..{}", .{ start, end });
            return if (end == start) null else .{ .start = start, .end = end };
        }
    };

    fn init(allocator: Allocator, len: usize) Allocator.Error!Blocks {
        // set all blocks as available
        return .{ .bitset = try .initFull(allocator, len) };
    }

    fn capacity(self: Blocks) usize {
        return self.bitset.capacity();
    }
    fn count(self: Blocks, state: BlockState) usize {
        return switch (state) {
            .used => self.capacity() - self.bitset.count(),
            .available => self.bitset.count(),
        };
    }

    fn findAvailable(self: Blocks) ?usize {
        return self.bitset.findFirstSet();
    }

    fn markAs(self: *Blocks, state: BlockState, range: Range) void {
        self.bitset.setRangeValue(.{
            .start = range.start,
            .end = range.end,
        }, state.toBool());
    }

    fn parentRange(self: Blocks, state: BlockState, range: Range) ?Range {
        if (self.bitset.capacity() <= 1) return null;
        return .init(
            start: {
                if (range.start & 1 == 0) {
                    break :start range.start / 2;
                }
                if (state == .used) {
                    //    parent <-- should mark as .used
                    //    /    \
                    // buddy, .used, .used, ...
                    //       ^ bit_range.start
                    break :start range.start / 2;
                }
                const buddy_index = range.start - 1;
                const buddy_state = BlockState.fromBool(self.bitset.isSet(buddy_index));
                if (buddy_state == .used) {
                    //    parent <-- should not mark as .available if buddy == .used
                    //    /    \
                    // buddy, .available, .available, ...
                    //       ^ bit_range.start
                    break :start range.start / 2 + 1;
                } else {
                    break :start range.start / 2;
                }
            },
            end: {
                if (range.end & 1 == 0) {
                    break :end range.end / 2;
                }
                if (state == .used) {
                    //         parent <-- should mark as .used
                    //         /    \
                    // ..., .used, buddy
                    //            ^ bit_range.end
                    break :end range.end / 2 + 1;
                }
                const buddy_index = range.end;
                const buddy_state = BlockState.fromBool(self.bitset.isSet(buddy_index));
                if (buddy_state == .used) {
                    //              parent <-- should not mark as .available if buddy == .used
                    //              /    \
                    // ..., .available, buddy
                    //                 ^ bit_range.end
                    break :end range.end / 2;
                } else {
                    break :end range.end / 2 + 1;
                }
            },
        );
    }
    test parentRange {
        var buf: [10]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        var blocks: Blocks = try .init(fba.allocator(), 16);
        try expectEqual(Range.init(2, 3), blocks.parentRange(.used, Range.init(4, 6).?));
        blocks.markAs(.used, Range.init(3, 11).?);
        try expectEqual(Range.init(1, 6), blocks.parentRange(.used, Range.init(3, 11).?));
        blocks.markAs(.available, Range.init(5, 9).?);
        try expectEqual(Range.init(3, 4), blocks.parentRange(.available, Range.init(5, 9).?));
    }
};

fn expectEqual(expected: anytype, actual: @TypeOf(expected)) !void {
    if (!std.meta.eql(expected, actual)) {
        log.err("expected: {any}", .{expected});
        log.err("  actual: {any}", .{actual});
        return std.testing.expect(false);
    }
}
