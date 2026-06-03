const std = @import("std");
const log = std.log.scoped(.fdt);

const Be = @import("endian.zig").Big;

const Fdt = @This();

header: *const Header,
reserved_memories: []const ReservedMemory,
structure_block: []const u8,
strings_block: []const u8,

const supported_version: u32 = 17;

pub fn init(base_addr: usize) !Fdt {
    const header: *const Header = try .fromAddr(base_addr);
    const self: Fdt = .{
        .header = header,
        .reserved_memories = b: {
            const ptr = header.memoryReservationBlock();
            for (0..header.dt_struct_offset.toNative() / @sizeOf(ReservedMemory)) |i| {
                if (ptr[i].isZero()) break :b ptr[0..i];
            }
            return error.InvalidFormat;
        },
        .structure_block = header.structureBlock(),
        .strings_block = header.stringsBlock(),
    };
    var r: std.Io.Reader = .fixed(self.structure_block);
    while (try TokenWithData.read(&r, self.strings_block)) |t| {
        log.debug("token: {f}", .{t});
    }
    return self;
}

const TokenWithData = union(enum) {
    begin_node: []const u8,
    property: Property,
    end_node,

    fn read(structure_block: *std.Io.Reader, strings_block: []const u8) !?TokenWithData {
        const token: Token = try .read(structure_block);
        return sw: switch (token) {
            .begin_node => .{
                .begin_node = try structure_block.takeSentinel(0),
            },
            .property => .{
                .property = try .read(structure_block, strings_block),
            },
            .end_node => .end_node,
            .nop => continue :sw try .read(structure_block),
            .end => null,
        };
    }

    pub fn format(self: TokenWithData, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .begin_node => |name| try writer.print("{s} {{", .{name}),
            .property => |prop| try writer.print("{f}", .{prop}),
            .end_node => try writer.writeByte('}'),
        }
    }
};

const Token = enum(u32) {
    begin_node = 1,
    end_node = 2,
    property = 3,
    nop = 4,
    end = 9,

    fn read(structure_block: *std.Io.Reader) std.Io.Reader.TakeEnumError!Token {
        comptime std.debug.assert(4 == @alignOf(Token));
        // FIXME: is this safe?
        structure_block.seek = std.mem.alignForward(usize, structure_block.seek, @alignOf(Token));
        return structure_block.takeEnum(Token, .big);
    }
};

const Property = struct {
    name: []const u8,
    value: []align(@alignOf(u32)) const u8,

    fn read(structure_block: *std.Io.Reader, strings_block: []const u8) std.Io.Reader.Error!Property {
        const len = try structure_block.takeInt(u32, .big);
        const name_start = try structure_block.takeInt(u32, .big);
        const name_end = std.mem.findScalarPos(u8, strings_block, name_start, 0) orelse return error.EndOfStream;
        return .{
            .name = strings_block[name_start..name_end],
            .value = @alignCast(try structure_block.take(len)),
        };
    }

    pub fn format(self: Property, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.value.len == 0) {
            try writer.print("  {s};", .{self.name});
            return;
        }
        try writer.print("  {s} = ", .{self.name});
        if (self.name[0] == '#') {
            try writer.print("<{}>;", .{std.mem.bigToNative(u32, @bitCast(self.value[0..4].*))});
        } else if (std.mem.eql(u8, self.name, "compatible")) {
            try writer.print("\"{s}\";", .{self.value});
        } else if (std.mem.eql(u8, self.name, "reg") and self.value.len % 4 == 0) {
            try writer.writeByte('<');
            const casted: []const u32 = @ptrCast(self.value);
            for (casted, 0..) |n, i| {
                if (1 < casted.len and 0 < i) try writer.writeByte(' ');
                try writer.print("0x{X}", .{std.mem.bigToNative(u32, n)});
            }
            try writer.writeAll(">;");
        } else {
            try writer.print("{any};", .{self.value});
        }
    }
};

const ReservedMemory = extern struct {
    address: Be(u64),
    size: Be(u64),

    comptime {
        std.debug.assert(8 == @alignOf(ReservedMemory));
    }

    fn isZero(self: ReservedMemory) bool {
        return self.address.int == 0 and self.size.int == 0;
    }
};

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

    pub fn fromAddr(address: usize) error{ InvalidMagic, UnsupportedVersion }!*const Header {
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

    fn memoryReservationBlock(self: *const Header) [*]const ReservedMemory {
        const offest = self.reserved_memory_offset.toNative();
        return @ptrFromInt(@intFromPtr(self) + offest);
    }

    fn structureBlock(self: *const Header) []const u8 {
        const offest = self.dt_struct_offset.toNative();
        const bytes: [*]const u8 = @ptrFromInt(@intFromPtr(self) + offest);
        return bytes[0..self.dt_struct_size.toNative()];
    }

    fn stringsBlock(self: *const Header) []const u8 {
        const offest = self.dt_strings_offset.toNative();
        const bytes: [*]const u8 = @ptrFromInt(@intFromPtr(self) + offest);
        return bytes[0..self.dt_strings_size.toNative()];
    }
};
