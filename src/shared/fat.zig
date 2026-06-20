//! References:
//!
//! - https://elm-chan.org/docs/fat_e.html

const std = @import("std");

const shared = @import("root.zig");
const Le = shared.Le;

pub const BootSector = extern struct {
    comptime {
        std.debug.assert(512 == @sizeOf(BootSector));
    }

    jmp_boot: [3]u8,
    oem_name: [8]u8,
    bytes_per_sector: Le(u16) align(1),
    sectors_per_cluster: u8,
    reserved_sector_count: Le(u16) align(1),
    fat_count: u8,
    root_entry_count: Le(u16) align(1),
    /// - FAT12/16: valid only when total_sectors < 0x10000
    /// - FAT32: always invalid
    total_sectors_16: Le(u16) align(1),
    media: u8,
    /// - FAT12/16: always valid
    /// - FAT32: always invalid
    fat_size_16: Le(u16) align(1),
    sectors_per_track: Le(u16) align(1),
    head_count: Le(u16) align(1),
    hidden_sectors: Le(u32) align(1),
    /// - FAT12/16: valid only when total_sectors >= 0x10000
    /// - FAT32: always valid
    total_sectors_32: Le(u32) align(1),
    type_specific: extern union {
        fat12: Fat12Or16Specific,
        fat16: Fat12Or16Specific,
        fat32: Fat32Specific,
    },
    // Remaining bytes are filled by 0.

    pub const Fat12Or16Specific = extern struct {
        drive_num: u8,
        _bs_reserved: u8 = 0,
        boot_signature: u8,
        volume_id: Le(u32) align(1),
        volume_label: [11]u8,
        fs_name: [8]u8,
        boot_code: [448]u8,
        signature: Le(u16) align(1),
    };

    pub const Fat32Specific = extern struct {
        fat_size_32: Le(u32) align(1),
        ext_flags: Le(u16) align(1),
        fs_version: Le(u16) align(1),
        root_cluster: Le(u32) align(1),
        fs_info: Le(u16) align(1),
        boot_sector_backup: Le(u16) align(1),
        _bpb_reserved: [12]u8 = @splat(0),
        drive_num: u8,
        _bs_reserved: u8 = 0,
        boot_signature: u8,
        volume_id: Le(u32) align(1),
        volume_label: [11]u8,
        fs_name: [8]u8,
        boot_code: [420]u8,
        signature: Le(u16) align(1),
    };

    pub fn firstSector(self: *const BootSector) u32 {
        return self.reserved_sector_count.toNative();
    }

    pub fn firstRootDirSector(self: *const BootSector) u32 {
        return self.firstSector() + self.sectorCount();
    }

    pub fn firstDataSector(self: *const BootSector) u32 {
        return self.firstRootDirSector() + self.rootDirSectorCount();
    }

    pub fn sectorCount(self: *const BootSector) u32 {
        return if (0 < self.fat_size_16.toNative())
            self.fat_size_16.toNative() * self.fat_count
        else
            self.type_specific.fat32.fat_size_32.toNative() * self.fat_count;
    }

    pub fn rootDirSectorCount(self: *const BootSector) u32 {
        const directory_entry_size: u16 = 32;
        const sector_size = self.bytes_per_sector.toNative();
        return (directory_entry_size * self.root_entry_count.toNative() + sector_size - 1) / sector_size;
    }

    pub fn dataSectorCount(self: *const BootSector) u32 {
        return if (0 < self.total_sectors_16.toNative())
            @as(u32, self.total_sectors_16.toNative()) - self.firstDataSector()
        else
            self.total_sectors_32.toNative() - self.firstDataSector();
    }

    pub fn clusterCount(self: *const BootSector) u32 {
        return self.dataSectorCount() / self.sectors_per_cluster;
    }

    pub fn detectType(self: *const BootSector) enum { fat12, fat16, fat32 } {
        return switch (self.clusterCount()) {
            0...4085 => .fat12,
            4086...65525 => .fat16,
            else => .fat32,
        };
    }
};
