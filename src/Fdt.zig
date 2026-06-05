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
    return .{
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
}

pub inline fn nodes(self: Fdt) !ManagedNodeIterator {
    return .init(self.structure_block, self.strings_block);
}

const ManagedNodeIterator = struct {
    stack_buf: [32]Node,
    iterator: NodeIterator,

    inline fn init(structure_block: []const u8, strings_block: []const u8) !ManagedNodeIterator {
        var self: ManagedNodeIterator = undefined;
        self.iterator = try .init(structure_block, strings_block, &self.stack_buf);
        return self;
    }

    pub inline fn next(self: *ManagedNodeIterator) !?Node {
        return self.iterator.next();
    }
};

pub const Node = struct {
    name: []const u8,
    parent_address_cells: ?u32,
    parent_size_cells: ?u32,

    address_cells: ?u32 = null,
    size_cells: ?u32 = null,
    /// null-delimited string list
    compatible: ?[]const u8 = null,
    /// This field is not null only if parent_address_cells is greater than 0 and parent_size_cells is not null.
    reg: ?[]const u32 = null,

    pub fn compatibles(self: Node) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, self.compatible orelse "", std.ascii.control_code.nul);
    }

    pub fn isCompatibleWith(self: Node, target_arch: []const u8) bool {
        if (self.compatible == null) return false;
        var it = self.compatibles();
        while (it.next()) |arch| if (std.mem.eql(u8, arch, target_arch)) {
            return true;
        };
        return false;
    }

    pub fn registers(self: Node) ?RegisterIterator {
        const cells = self.reg orelse return null;
        return .{
            .cells = cells,
            .address_cells = self.parent_address_cells.?,
            .size_cells = self.parent_size_cells.?,
        };
    }

    fn setProperty(self: *Node, p: Property) void {
        if (std.mem.eql(u8, p.name, "#address-cells")) {
            if (p.value.len != 4) {
                log.warn("{s}: invalid #address-cells property: {any}", .{ self.name, p.value });
                return;
            }
            self.address_cells = std.mem.readInt(u32, p.value[0..@sizeOf(u32)], .big);
        } else if (std.mem.eql(u8, p.name, "#size-cells")) {
            if (p.value.len != 4) {
                log.warn("{s}: invalid #size-cells property: {any}", .{ self.name, p.value });
                return;
            }
            self.size_cells = std.mem.readInt(u32, p.value[0..@sizeOf(u32)], .big);
        } else if (std.mem.eql(u8, p.name, "compatible")) {
            if (p.value.len == 0 or p.value[p.value.len - 1] != std.ascii.control_code.nul) {
                log.warn("{s}: invalid compatible property: {any}", .{ self.name, p.value });
                return;
            }
            self.compatible = p.value[0 .. p.value.len - 1];
        } else if (std.mem.eql(u8, p.name, "reg")) {
            const parent_address_cells = self.parent_address_cells orelse {
                log.warn("{s}: reg property exists but #address-cells property does not exist in the parent node", .{self.name});
                return;
            };
            if (parent_address_cells == 0) {
                log.warn("{s}: reg property exists but #address-cells property of the parent node is 0", .{self.name});
                return;
            }
            const parent_size_cells = self.parent_size_cells orelse {
                log.warn("{s}: reg property exists but #size-cells property does not exist in the parent node", .{self.name});
                return;
            };
            if (p.value.len % ((parent_address_cells + parent_size_cells) * @sizeOf(u32)) != 0) {
                log.warn("{s}: invalid reg property: {any}", .{ self.name, p.value });
                return;
            }
            self.reg = @ptrCast(p.value);
        }
    }

    pub fn format(self: Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("/{s} {{ ", .{self.name});
        if (self.address_cells) |n| {
            try writer.print("#address-cells = <{}>; ", .{n});
        }
        if (self.size_cells) |n| {
            try writer.print("#size-cells = <{}>; ", .{n});
        }
        if (self.compatible != null) {
            try writer.print("compatible = ", .{});
            var it = self.compatibles();
            var i: usize = 0;
            while (it.next()) |arch| : (i += 1) {
                if (0 < i) try writer.print(", ", .{});
                try writer.print("\"{s}\"", .{arch});
            }
            try writer.print("; ", .{});
        }
        if (self.reg) |reg| {
            try writer.print("reg = <", .{});
            for (reg, 0..) |n, i| {
                if (1 < reg.len and 0 < i) try writer.writeByte(' ');
                try writer.print("0x{X}", .{std.mem.bigToNative(u32, n)});
            }
            try writer.writeAll(">; ");
        }
        try writer.print("}}", .{});
    }
};

pub const RegisterIterator = struct {
    cells: []const u32,
    address_cells: u32,
    size_cells: u32,
    index: usize = 0,

    /// The first call of this function must not be null.
    pub fn next(self: *RegisterIterator) ?Register {
        if (self.cells.len <= self.index) return null;
        const len = self.address_cells + self.size_cells;
        defer self.index += len;
        const cells = self.cells[self.index..][0..len];
        return .{
            .address_cells = cells[0..self.address_cells],
            .size_cells = cells[self.size_cells..],
        };
    }
};

pub const Register = struct {
    address_cells: []const u32,
    size_cells: []const u32,

    pub fn address(self: Register) u64 {
        const low = std.mem.bigToNative(u32, self.address_cells[self.address_cells.len - 1]);
        switch (self.address_cells.len) {
            0 => unreachable,
            1 => return low,
            else => {
                const high: u64 = std.mem.bigToNative(u32, self.address_cells[self.address_cells.len - 2]);
                return (high << 32) | low;
            },
        }
    }
};

pub const NodeIterator = struct {
    structure_block: std.Io.Reader,
    strings_block: []const u8,
    stack: std.ArrayList(Node),

    fn init(structure_block: []const u8, strings_block: []const u8, stack_buf: []Node) !NodeIterator {
        var self: NodeIterator = .{
            .structure_block = .fixed(structure_block),
            .strings_block = strings_block,
            .stack = .initBuffer(stack_buf),
        };
        const first = try TokenWithData.read(&self.structure_block, self.strings_block) orelse {
            log.err("root node not found", .{});
            return error.InvalidFormat;
        };
        switch (first) {
            .begin_node => |name| {
                if (0 < name.len) {
                    log.warn("name of the root node is not empty: {any}", .{name});
                }
                try self.stack.appendBounded(.{
                    .name = name,
                    .parent_address_cells = null,
                    .parent_size_cells = null,
                });
            },
            else => return error.InvalidFormat,
        }
        return self;
    }

    pub fn next(self: *NodeIterator) !?Node {
        var property_dest = self.stack.pop() orelse return null;
        sw: switch (try TokenWithData.read(&self.structure_block, self.strings_block) orelse {
            log.err("FDT_END after the node name \"{s}\"", .{property_dest.name});
            return error.InvalidFormat;
        }) {
            .begin_node => |name| {
                self.stack.appendAssumeCapacity(property_dest);
                try self.stack.appendBounded(.{
                    .name = name,
                    .parent_address_cells = property_dest.address_cells,
                    .parent_size_cells = property_dest.size_cells,
                });
                return property_dest;
            },
            .property => |property| {
                property_dest.setProperty(property);
                continue :sw try TokenWithData.read(&self.structure_block, self.strings_block) orelse {
                    log.err("FDT_END after the property value", .{});
                    return error.InvalidFormat;
                };
            },
            .end_node => switch (try TokenWithData.read(&self.structure_block, self.strings_block) orelse {
                if (0 < self.stack.items.len) {
                    log.err("missing FDT_END_NODE", .{});
                    return error.InvalidFormat;
                }
                return null;
            }) {
                .begin_node => |name| {
                    const parent = self.stack.getLastOrNull() orelse {
                        log.err("parent node not found", .{});
                        return error.InvalidFormat;
                    };
                    try self.stack.appendBounded(.{
                        .name = name,
                        .parent_address_cells = parent.address_cells,
                        .parent_size_cells = parent.size_cells,
                    });
                    return property_dest;
                },
                .property => {
                    log.err("FDT_PROP after FDT_END_NODE", .{});
                    return error.InvalidFormat;
                },
                .end_node => {
                    if (self.stack.pop() == null) {
                        log.err("too many FDT_END_NODE", .{});
                        return error.InvalidFormat;
                    }
                    continue :sw .end_node;
                },
            },
        }
    }
};

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
