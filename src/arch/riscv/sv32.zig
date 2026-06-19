const std = @import("std");
const Allocator = std.mem.Allocator;

const csr = @import("csr.zig");

pub const page_size = b: {
    std.debug.assert(@FieldType(VirtAddr, "offset") == @FieldType(PhysAddr, "offset"));
    break :b 1 << @bitSizeOf(@FieldType(VirtAddr, "offset"));
};

pub const VirtAddr = packed struct(u32) {
    offset: u12,
    page_number_0: u10,
    page_number_1: u10,

    pub const Level = enum {
        lv1,
        lv0,

        pub const root: Level = .lv1;

        pub fn lower(self: Level) Level {
            return switch (self) {
                .lv1 => .lv0,
                .lv0 => @compileError("level 0 is the lowest level"),
            };
        }
    };

    fn PageNumberType(level: Level) type {
        return @FieldType(VirtAddr, switch (level) {
            .lv0 => "page_number_0",
            .lv1 => "page_number_1",
        });
    }

    fn entryCount(level: Level) usize {
        return 1 << @bitSizeOf(PageNumberType(level));
    }
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
    const entry_count = VirtAddr.entryCount(level);

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

        fn getEntry(self: Self, vpn: VirtAddr.PageNumberType(level)) *Entry {
            return &self.entries[vpn];
        }

        pub fn mapPage(
            table1: PageTable(.root),
            allocator: Allocator,
            vaddr: u32,
            entry: PageTable(.lv0).Entry,
        ) Allocator.Error!void {
            const virt_addr: VirtAddr = @bitCast(vaddr);
            std.debug.assert(virt_addr.offset == 0);
            const entry1 = table1.getEntry(virt_addr.page_number_1);
            const table0 = try entry1.getOrInitTable(allocator);
            const entry0 = table0.getEntry(virt_addr.page_number_0);
            entry0.* = entry;
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
