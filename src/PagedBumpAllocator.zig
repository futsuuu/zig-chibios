const std = @import("std");

const PagedBumpAllocator = @This();

test PagedBumpAllocator {
    var bump: PagedBumpAllocator = .init;
    defer bump.deinit();
    const a = bump.allocator();
    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorLargeAlignment(a);
    try std.heap.testAllocatorAlignedShrink(a);
}

page_allocator: std.mem.Allocator,
current: Node,

pub const init: PagedBumpAllocator = .{
    .page_allocator = std.heap.page_allocator,
    .current = .nil,
};

pub fn deinit(self: PagedBumpAllocator) void {
    self.current.deinit(self.page_allocator);
}

pub fn allocator(self: *PagedBumpAllocator) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

const page_size = std.heap.pageSize();

const Node = struct {
    /// If `node.fba.buffer` is empty, `node` is the root node.
    /// Otherwise, `node.fba.buffer.ptr` can be casted to the parent node.
    fba: std.heap.FixedBufferAllocator,

    const nil: Node = .{
        .fba = .{
            .buffer = &.{},
            .end_index = 0,
        },
    };

    fn isNil(self: Node) bool {
        return self.fba.buffer.len == 0;
    }

    fn init(page_allocator: std.mem.Allocator, len: usize, parent: Node) ?Node {
        std.debug.assert(0 < len);
        std.debug.assert(std.mem.isAligned(len, page_size));
        var self: Node = .{
            .fba = .init(page_allocator.alloc(u8, len) catch return null),
        };
        const parent_area = self.fba.allocator().create(Node) catch {
            comptime std.debug.assert(@sizeOf(Node) < page_size);
            unreachable;
        };
        std.debug.assert(@intFromPtr(parent_area) == @intFromPtr(self.fba.buffer.ptr));
        parent_area.* = parent;
        return self;
    }

    fn deinit(self: Node, page_allocator: std.mem.Allocator) void {
        if (self.isNil()) return;
        var current = self;
        while (current.getParent()) |parent_ptr| {
            const parent = parent_ptr.*;
            page_allocator.free(self.fba.buffer);
            current = parent;
        }
    }

    fn getParent(self: Node) ?*Node {
        comptime std.debug.assert(@alignOf(Node) < page_size);
        const casted: *Node = @alignCast(@ptrCast(self.fba.buffer.ptr));
        return if (casted.isNil()) null else casted;
    }
};

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const self: *PagedBumpAllocator = @ptrCast(@alignCast(ctx));
    if (std.heap.FixedBufferAllocator.alloc(&self.current.fba, len, alignment, ra)) |mem| {
        return mem;
    }
    const alloc_len = std.mem.alignForward(usize, len + @max(@sizeOf(Node), alignment.toByteUnits()), page_size);
    const next = Node.init(self.page_allocator, alloc_len, self.current) orelse return null;
    self.current = next;
    return std.heap.FixedBufferAllocator.alloc(&self.current.fba, len, alignment, ra) orelse unreachable;
}

fn resize(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ra: usize,
) bool {
    const self: *PagedBumpAllocator = @ptrCast(@alignCast(ctx));
    if (!self.current.fba.ownsSlice(memory)) return false;
    return std.heap.FixedBufferAllocator.resize(&self.current.fba, memory, alignment, new_len, ra);
}

fn remap(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ra: usize,
) ?[*]u8 {
    const self: *PagedBumpAllocator = @ptrCast(@alignCast(ctx));
    if (!self.current.fba.ownsSlice(memory)) return null;
    return std.heap.FixedBufferAllocator.remap(&self.current.fba, memory, alignment, new_len, ra);
}

fn free(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    ra: usize,
) void {
    const self: *PagedBumpAllocator = @ptrCast(@alignCast(ctx));
    if (!self.current.fba.ownsSlice(memory)) return;
    std.heap.FixedBufferAllocator.free(&self.current.fba, memory, alignment, ra);
}
