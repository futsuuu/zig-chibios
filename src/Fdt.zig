const std = @import("std");
const log = std.log.scoped(.fdt);

const Be = @import("endian.zig").Big;

const Fdt = @This();

header: *const Header,
reserved_memories: []const ReservedMemory,

const supported_version: u32 = 17;

pub fn init(base_addr: usize) error{InvalidMagic,UnsupportedVersion}!Fdt {
    const header: *const Header = try .fromAddr(base_addr);
    const reserved_memories = b: {
        const offest = header.reserved_memory_offset.toNative();
        const ptr: [*]const ReservedMemory = @ptrFromInt(base_addr + offest);
        for (0..header.dt_struct_offset.toNative() / @sizeOf(ReservedMemory)) |i| {
            if (ptr[i].isZero()) break :b ptr[0..i];
        }
        std.debug.panic("too many memory reservation entries in DTB", .{});
    };
    // TODO: parse structure block
    return .{
        .header = header,
        .reserved_memories = reserved_memories,
    };
}

pub const Header = extern struct {
    const expected_magic: u32 = 0xd00dfeed;

    magic: Be(u32),
    total_size: Be(u32),
    dt_struct_offset: Be(u32),
    dt_strings_offset: Be(u32),
    reserved_memory_offset: Be(u32),
    version: Be(u32),
    last_compatible_version: Be(u32),
    boot_cpu_physical_id: Be(u32),
    dt_strings_size: Be(u32),
    dt_struct_size: Be(u32),

    pub fn fromAddr(address: usize) error{InvalidMagic,UnsupportedVersion}!*const Header {
        const self: *const Header = @ptrFromInt(address);
        if (self.magic.toNative() != expected_magic) {
            log.err("invalid magic: expected 0x{x}, got 0x{x}", .{
                expected_magic,
                self.magic.toNative(),
            });
            return error.InvalidMagic;
        }
        if (supported_version < self.last_compatible_version.toNative()) {
            log.err("unsupported version: last compatible version is {}, but supported version is {}", .{
                self.last_compatible_version.toNative(),
                supported_version,
            });
            return error.UnsupportedVersion;
        }
        log.debug("version {}", .{self.version.toNative()});
        return self;
    }
};

const ReservedMemory = extern struct {
    address: Be(u64),
    size: Be(u64),

    fn isZero(self: ReservedMemory) bool {
        return self.address.int == 0 and self.size.int == 0;
    }
};

const Token = enum(u32) {
    begin_node = 1,
    end_node = 2,
    property = 3,
    nop = 4,
    end = 9,
};

const Property = extern struct {
    len: Be(u32),
    name_offset: Be(u32),
};
