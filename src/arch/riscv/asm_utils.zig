pub const xlen = @bitSizeOf(usize);
pub const xlenb = @divExact(xlen, 8);
pub const load_xlen = switch (xlen) {
    32 => "lw",
    64 => "ld",
    else => unreachable,
};
pub const store_xlen = switch (xlen) {
    32 => "sw",
    64 => "sd",
    else => unreachable,
};
