const std = @import("std");

const shared = @import("root.zig");
const Le = shared.Le;

/// Master Boot Record
pub const Mbr = extern struct {
    comptime {
        std.debug.assert(512 == @sizeOf(Mbr));
    }

    boot_code: [446]u8 = @splat(0),
    partitions: [4]Partition align(1),
    signature: Le(u16) align(1) = .fromNative(expected_signature),

    pub const expected_signature: u16 = 0xAA55;

    pub const Partition = extern struct {
        boot_id: BootId,
        start_head: u8,
        start_cs: Le(packed struct(u16) {
            cylinder: u10,
            sector: u6,
        }),
        type: Type,
        end_head: u8,
        end_cs: Le(packed struct(u16) {
            cylinder: u10,
            sector: u6,
        }),
        offset: Le(u32),
        size: Le(u32),

        pub const BootId = enum(u8) {
            non_bootable = 0x00,
            bootable = 0x80,
            /// Invalid
            _,
        };

        /// https://en.wikipedia.org/wiki/Partition_type
        pub const Type = enum(u8) {
            free = 0x00,
            _,

            pub fn isFat(self: Type) bool {
                return switch (@intFromEnum(self)) {
                    0x01,
                    0x04,
                    0x06,
                    0x0B,
                    0x0C,
                    0x0E,
                    => true,
                    else => false,
                };
            }
        };
    };
};
