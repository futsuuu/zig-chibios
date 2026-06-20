const std = @import("std");
const Allocator = std.mem.Allocator;

const csr = @import("../csr.zig");

pub const page_size = b: {
    std.debug.assert(@FieldType(VirtAddr, "offset") == @FieldType(PhysAddr, "offset"));
    break :b 1 << @bitSizeOf(@FieldType(VirtAddr, "offset"));
};

pub const VirtAddr = packed struct(u32) {
    offset: u12,
    page_number: PageNumber,

    pub const Level = enum {
        lv0,
        lv1,

        pub const root: Level = .lv1;

        pub fn lower(self: Level) Level {
            return switch (self) {
                .lv0 => @compileError("level 0 is the lowest level"),
                .lv1 => .lv0,
            };
        }
    };

    pub const PageNumber = packed struct {
        lv0: u10,
        lv1: u10,

        fn FieldType(level: Level) type {
            _ = level;
            return u10;
        }

        fn get(self: PageNumber, comptime level: Level) FieldType(level) {
            return switch (level) {
                .lv0 => self.lv0,
                .lv1 => self.lv1,
            };
        }

        fn entryCount(level: Level) usize {
            return 1 << @bitSizeOf(FieldType(level));
        }
    };
};

pub const PhysAddr = packed struct(u34) {
    offset: u12,
    page_number: PageNumber,

    pub const PageNumber = packed struct {
        num: u22,

        pub fn fromPtr(ptr: *align(page_size) const anyopaque) PageNumber {
            return .{ .num = @intCast(@intFromPtr(ptr) / page_size) };
        }

        pub fn toPtr(self: PageNumber) *align(page_size) anyopaque {
            return @ptrFromInt(@as(usize, self.num) * page_size);
        }
    };
};

pub fn PageTable(level: VirtAddr.Level) type {
    const entry_count = VirtAddr.PageNumber.entryCount(level);

    return struct {
        const Self = @This();

        entries: *align(page_size) [entry_count]Entry,

        pub fn init(allocator: Allocator) Allocator.Error!Self {
            const entries = try allocator.alignedAlloc(
                Entry,
                .fromByteUnits(page_size),
                entry_count,
            );
            @memset(entries, .{
                .ppn = undefined,
                .flags = .{ .valid = false },
            });
            return .{ .entries = entries[0..entry_count] };
        }

        pub fn deinit(self: Self, allocator: Allocator) void {
            allocator.free(@as([]Entry, self.entries));
        }

        pub fn activate(self: PageTable(.root)) void {
            const satp: csr.satp.Format = .{
                .mode = .sv32,
                .phys_page_num = self.getPageNumber().num,
                .addr_space_id = 0,
            };
            asm volatile (
                \\ sfence.vma
                \\ csrw satp, %[satp]
                \\ sfence.vma
                :
                : [satp] "r" (satp),
            );
        }

        fn fromPageNumber(ppn: PhysAddr.PageNumber) Self {
            return .{ .entries = @ptrCast(ppn.toPtr()) };
        }

        fn getPageNumber(self: Self) PhysAddr.PageNumber {
            return .fromPtr(self.entries);
        }

        fn getEntry(self: Self, vpn: VirtAddr.PageNumber.FieldType(level)) *Entry {
            return &self.entries[vpn];
        }

        pub fn mapPage(
            self: Self,
            allocator: Allocator,
            vpn: VirtAddr.PageNumber,
            leaf_entry: PageTable(.lv0).Entry,
        ) Allocator.Error!void {
            const entry = self.getEntry(vpn.get(level));
            if (level == .lv0) {
                entry.* = leaf_entry;
                return;
            }
            const child: PageTable(level.lower()) = if (entry.flags.valid) .fromPageNumber(entry.ppn) else b: {
                const child: PageTable(level.lower()) = try .init(allocator);
                entry.* = .init(child.getPageNumber(), .ptr);
                break :b child;
            };
            try child.mapPage(allocator, vpn, leaf_entry);
        }

        pub const Entry = packed struct(u32) {
            flags: Flags,
            ppn: PhysAddr.PageNumber,

            pub const Flags = packed struct {
                valid: bool = true,
                readable: bool = false,
                writable: bool = false,
                executable: bool = false,
                usermode: bool = false,
                global: bool = false,
                accessed: bool = false,
                dirty: bool = false,
                _: u2 = 0,

                pub fn format(self: Flags, writer: *std.Io.Writer) std.Io.Writer.Error!void {
                    try writer.writeByte(if (0 < self._ & 0b10) '1' else '-');
                    try writer.writeByte(if (0 < self._ & 0b01) '1' else '-');
                    try writer.writeByte(if (self.dirty) 'd' else '-');
                    try writer.writeByte(if (self.accessed) 'a' else '-');
                    try writer.writeByte(if (self.global) 'g' else '-');
                    try writer.writeByte(if (self.usermode) 'u' else '-');
                    try writer.writeByte(if (self.executable) 'x' else '-');
                    try writer.writeByte(if (self.writable) 'w' else '-');
                    try writer.writeByte(if (self.readable) 'r' else '-');
                    try writer.writeByte(if (self.valid) 'v' else '-');
                }

                const valid_flags = if (level == .lv0) .{ r, rw, x, rx, rwx } else .{ptr};
                const ptr: Flags = .{};
                pub const r: Flags = .{ .readable = true };
                pub const rw: Flags = .{ .readable = true, .writable = true };
                pub const x: Flags = .{ .executable = true };
                pub const rx: Flags = .{ .readable = true, .executable = true };
                pub const rwx: Flags = .{ .readable = true, .writable = true, .executable = true };
            };

            pub fn init(ppn: PhysAddr.PageNumber, comptime flags: Flags) Entry {
                comptime for (Flags.valid_flags) |valid| {
                    if (flags == valid) break;
                } else {
                    @compileError(std.fmt.comptimePrint("invalid flags for {}: {f}", .{ level, flags }));
                };
                return .{ .ppn = ppn, .flags = flags };
            }

            fn getOrInitTable(self: *Entry, allocator: Allocator) Allocator.Error!PageTable(level.lower()) {
                if (self.flags.valid) {
                    return .fromPageNumber(self.ppn);
                }
                const table: PageTable(level.lower()) = try .init(allocator);
                self.* = .init(table.getPageNumber(), .ptr);
                return table;
            }

            fn getAddr(self: Entry) PhysAddr {
                return .{ .page_number = self.ppn, .offset = 0 };
            }
        };
    };
}
