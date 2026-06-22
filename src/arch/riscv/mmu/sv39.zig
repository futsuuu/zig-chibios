const std = @import("std");
const Allocator = std.mem.Allocator;

const csr = @import("../csr.zig");

const common = @import("common.zig");

pub const page_size = b: {
    std.debug.assert(@FieldType(VirtAddr, "offset") == @FieldType(PhysAddr, "offset"));
    break :b 1 << @bitSizeOf(@FieldType(VirtAddr, "offset"));
};

pub const VirtAddr = packed struct(u39) {
    offset: u12,
    page_number: PageNumber,

    pub const Level = enum {
        lv0,
        lv1,
        lv2,

        pub const root: Level = .lv2;

        pub fn lower(self: Level) Level {
            return switch (self) {
                .lv0 => @compileError("level 0 is the lowest level"),
                .lv1 => .lv0,
                .lv2 => .lv1,
            };
        }
    };

    pub const PageNumber = packed struct {
        lv0: u9,
        lv1: u9,
        lv2: u9,

        fn FieldType(level: Level) type {
            _ = level;
            return u9;
        }

        fn get(self: PageNumber, comptime level: Level) FieldType(level) {
            return switch (level) {
                .lv0 => self.lv0,
                .lv1 => self.lv1,
                .lv2 => self.lv2,
            };
        }

        fn entryCount(level: Level) usize {
            return 1 << @bitSizeOf(FieldType(level));
        }
    };
};

pub const PhysAddr = packed struct(u56) {
    offset: u12,
    page_number: PageNumber,

    pub const PageNumber = packed struct {
        num: u44,

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
            if (level != .lv0) {
                for (self.entries) |entry| if (entry.getPointedTable()) |child| {
                    child.deinit(allocator);
                };
            }
            allocator.free(@as([]align(page_size) Entry, self.entries));
        }

        pub fn activate(self: PageTable(.root)) void {
            const satp: csr.satp.Format = .{
                .mode = .sv39,
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
            const child = entry.getPointedTable() orelse b: {
                const child: PageTable(level.lower()) = try .init(allocator);
                entry.* = .init(child.getPageNumber(), .ptr);
                break :b child;
            };
            try child.mapPage(allocator, vpn, leaf_entry);
        }

        pub const Entry = packed struct(u64) {
            flags: common.Flags,
            ppn: PhysAddr.PageNumber,
            _: u7 = 0,
            type: MemoryType = .physical_memory_attributes,
            napot: bool = false,

            pub const MemoryType = enum(u2) {
                physical_memory_attributes = 0,
                non_cachable = 1,
                io = 2,
            };

            pub fn init(ppn: PhysAddr.PageNumber, comptime flags: common.Flags) Entry {
                comptime flags.assertValid();
                return .{ .ppn = ppn, .flags = flags };
            }

            pub fn getPointedTable(self: Entry) ?PageTable(level.lower()) {
                return if (self.flags.valid) .fromPageNumber(self.ppn) else null;
            }
        };
    };
}
