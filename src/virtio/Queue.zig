const endian = @import("../endian.zig");
const Le = endian.Little;

pub const Descriptor = packed struct {
    /// Buffer address
    addr: Le(u64),
    /// Buffer length
    len: Le(u32),
    /// Buffer ID
    id: Le(u16),
    /// The flags depending on descriptor type
    flags: Le(u16),
};

pub const EventSuppresion = packed struct {};
