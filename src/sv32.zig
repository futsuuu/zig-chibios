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

    pub const Layer = u1;
    pub const max_layer: Layer = 1;

    fn PageNumber(layer: Layer) type {
        return @FieldType(VirtAddr, switch (layer) {
            0 => "page_number_0",
            1 => "page_number_1",
        });
    }

    fn entryCount(layer: Layer) usize {
        return 1 << @bitSizeOf(PageNumber(layer));
    }
};

pub const PhysAddr = packed struct(u34) {
    offset: u12,
    page_number: u22,

    pub fn getPageNumber(ptr: *const anyopaque) u22 {
        return @intCast(@intFromPtr(ptr) / page_size);
    }
};

pub const RootPageTable = PageTable(VirtAddr.max_layer);
pub const LeafEntry = PageTable(0).Entry;

pub fn PageTable(layer: VirtAddr.Layer) type {
    const entry_count = VirtAddr.entryCount(layer);

    return struct {
        const Self = @This();

        entries: [entry_count]Entry,

        pub fn init(allocator: Allocator) Allocator.Error!*Self {
            const entries = try allocator.alignedAlloc(
                Entry,
                .fromByteUnits(page_size),
                entry_count,
            );
            return @ptrCast(entries.ptr);
        }

        pub fn activate(self: *RootPageTable) void {
            const satp: csr.satp.Format = .{
                .mode = .sv32,
                .phys_page_num = self.getAddr().page_number,
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

        fn getAddr(self: *const Self) PhysAddr {
            return @bitCast(@as(u34, @intCast(@intFromPtr(self))));
        }

        fn fromAddr(paddr: PhysAddr) *Self {
            return @ptrFromInt(@as(usize, @intCast(@as(u34, @bitCast(paddr)))));
        }

        fn getEntry(self: *Self, vpn: VirtAddr.PageNumber(layer)) *Entry {
            return &self.entries[vpn];
        }

        pub fn mapPage(
            table1: *RootPageTable,
            allocator: Allocator,
            vaddr: u32,
            entry: LeafEntry,
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
            ppn: u22,

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

                const ptr: Flags = if (layer > 0) .{} else unreachable;
                pub const rwx: Flags = if (layer == 0) .{
                    .readable = true,
                    .writable = true,
                    .executable = true,
                } else unreachable;
            };

            pub fn init(ppn: u22, flags: Flags) Entry {
                return .{ .ppn = ppn, .flags = flags };
            }

            fn getOrInitTable(self: *Entry, allocator: Allocator) Allocator.Error!*PageTable(layer - 1) {
                if (self.flags.valid) {
                    return .fromAddr(self.getAddr());
                }
                const table: *PageTable(layer - 1) = try .init(allocator);
                const paddr = table.getAddr();
                std.debug.assert(paddr.offset == 0);
                self.* = .init(paddr.page_number, .ptr);
                return table;
            }

            fn getAddr(self: Entry) PhysAddr {
                return .{ .page_number = self.ppn, .offset = 0 };
            }
        };
    };
}
