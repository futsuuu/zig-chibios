const builtin = @import("builtin");

pub const sv32 = @import("mmu/sv32.zig");
pub const sv39 = @import("mmu/sv39.zig");

pub const native = switch (builtin.target.ptrBitWidth()) {
    32 => sv32,
    64 => sv39,
    else => unreachable,
};
