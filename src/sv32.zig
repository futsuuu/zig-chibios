const std = @import("std");

const VirtAddr = packed struct(u32) {
    offset: u12,
    vpn0: u10,
    vpn1: u10,
};

const PhysAddr = packed struct(u34) {
    offset: u12,
    ppn0: u10,
    ppn1: u12,

    fn getPageNumber(self: PhysAddr) u22 {
        return @as(packed struct(u34) { _: u12, ppn: u22 }, @bitCast(self)).ppn;
    }
};

pub const PageTable = struct {
    entries: [entry_count]Entry,

    const entry_count = (1 << 12) / @sizeOf(Entry);

    pub fn init(a: std.mem.Allocator) *PageTable {
        const entries = a.alignedAlloc(
            Entry,
            .fromByteUnits(@sizeOf(PageTable)),
            entry_count,
        ) catch @panic("OOM");
        return @ptrCast(entries.ptr);
    }

    pub fn activate(self: *const PageTable) void {
        const satp: packed struct(u32) {
            ppn: u22,
            asid: u9 = 0,
            mode: enum(u1) { bare = 0, sv32 = 1 } = .sv32,
        } = .{
            .ppn = self.getAddr().getPageNumber(),
        };
        asm volatile (
            \\ sfence.vma
            \\ csrw satp, %[satp]
            \\ sfence.vma
            :
            : [satp] "r" (satp),
        );
    }

    fn getAddr(self: *const PageTable) PhysAddr {
        return @bitCast(@as(u34, @intCast(@intFromPtr(self))));
    }

    fn fromAddr(paddr: PhysAddr) *PageTable {
        return @ptrFromInt(@as(usize, @intCast(@as(u34, @bitCast(paddr)))));
    }

    pub fn mapPage(
        table1: *PageTable,
        a: std.mem.Allocator,
        vaddr: u32,
        paddr: u34,
        flags: Entry.Flags,
    ) void {
        const virt_addr: VirtAddr = @bitCast(vaddr);
        const phys_addr: PhysAddr = @bitCast(paddr);
        std.debug.assert(virt_addr.offset == 0);
        const entry1 = &table1.entries[@intCast(virt_addr.vpn1)];
        if (!entry1.flags.valid) {
            const table0: *PageTable = .init(a);
            entry1.* = .init(table0.getAddr(), .{});
        }
        const table0: *PageTable = .fromAddr(entry1.getAddr());
        const entry0 = &table0.entries[@intCast(virt_addr.vpn0)];
        entry0.* = .init(phys_addr, flags);
    }

    pub const Entry = packed struct(u32) {
        flags: Flags,
        ppn0: u10,
        ppn1: u12,

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

            pub const rwx__: Flags = .{ .readable = true, .writable = true, .executable = true };
        };

        fn init(paddr: PhysAddr, flags: Flags) Entry {
            std.debug.assert(paddr.offset == 0);
            return .{
                .flags = flags,
                .ppn0 = paddr.ppn0,
                .ppn1 = paddr.ppn1,
            };
        }

        fn getAddr(self: Entry) PhysAddr {
            return .{
                .offset = 0,
                .ppn0 = self.ppn0,
                .ppn1 = self.ppn1,
            };
        }
    };
};
