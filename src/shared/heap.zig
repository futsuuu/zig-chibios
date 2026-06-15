const std = @import("std");

pub const PagedBumpAllocator = @import("heap/PagedBumpAllocator.zig");
const buddy_allocator = @import("heap/buddy_allocator.zig");
pub const BuddyAllocator = buddy_allocator.BuddyAllocator;
pub const BuddyAllocatorConfig = buddy_allocator.Config;

comptime {
    std.testing.refAllDecls(@This());
}
