//! References:
//!
//! - https://elm-chan.org/docs/fat_e.html

const std = @import("std");
const log = std.log.scoped(.fat);

const shared = @import("root.zig");
const Le = shared.Le;

pub const Type = enum {
    fat12,
    fat16,
    fat32,
};

fn Magic(Int: type, expected: Int) type {
    return enum(Int) {
        valid = expected,
        _,

        fn assertValid(self: @This()) error{InvalidMagic}!void {
            if (self == .valid) return;
            log.err("invalid magic: expected 0x{X}, got 0x{X}", .{ expected, @intFromEnum(self) });
            return error.InvalidMagic;
        }
    };
}

pub const BootSector = struct {
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    sectors_per_fat: u32,
    fat_count: u8,
    first_root_dir_sector: u32,
    first_data_sector: u32,
    first_fat_sector: u32,

    volume_id: u32,
    volume_label: [11]u8,

    type: union(Type) {
        fat12,
        fat16,
        fat32,
    },

    const max_fat12_cluster_count: u32 = 4085;

    pub fn firstSectorOfCluster(self: *const BootSector, cluster: u32) u32 {
        return self.first_data_sector + (cluster - 2) * self.sectors_per_cluster;
    }

    test firstSectorOfCluster {
        const boot: BootSector = .{
            .bytes_per_sector = 512,
            .sectors_per_cluster = 1,
            .first_root_dir_sector = 100,
            .volume_id = 0,
            .volume_label = undefined,
            .type = .fat16,
            .first_data_sector = 200,
            .first_fat_sector = 50,
            .sectors_per_fat = 10,
            .fat_count = 2,
        };
        try std.testing.expectEqual(200, boot.firstSectorOfCluster(2));
        try std.testing.expectEqual(201, boot.firstSectorOfCluster(3));
        try std.testing.expectEqual(300, boot.firstSectorOfCluster(102));

        const boot2: BootSector = .{
            .bytes_per_sector = 1024,
            .sectors_per_cluster = 4,
            .first_root_dir_sector = 100,
            .volume_id = 0,
            .volume_label = undefined,
            .type = .fat16,
            .first_data_sector = 500,
            .first_fat_sector = 50,
            .sectors_per_fat = 10,
            .fat_count = 2,
        };
        try std.testing.expectEqual(500, boot2.firstSectorOfCluster(2));
        try std.testing.expectEqual(504, boot2.firstSectorOfCluster(3));
        try std.testing.expectEqual(900, boot2.firstSectorOfCluster(102));
    }

    pub fn entryLocation(self: *const BootSector, cluster: u32) EntryLocation {
        const bits_per_entry: u32 = switch (self.type) {
            .fat12 => @bitSizeOf(Entry(.fat12)),
            .fat16 => @bitSizeOf(Entry(.fat16)),
            .fat32 => @bitSizeOf(Entry(.fat32)),
        };
        // cluster * bits_per_entry can overflow?
        const byte_offset = (@as(u64, cluster) * bits_per_entry) / 8;
        return .{
            .sector = self.first_fat_sector + @as(u32, @intCast(byte_offset / self.bytes_per_sector)),
            .byte_offset = @intCast(byte_offset % self.bytes_per_sector),
        };
    }

    test entryLocation {
        const boot16: BootSector = .{
            .bytes_per_sector = 512,
            .sectors_per_cluster = 1,
            .first_root_dir_sector = 100,
            .volume_id = 0,
            .volume_label = undefined,
            .type = .fat16,
            .first_data_sector = 200,
            .first_fat_sector = 1,
            .sectors_per_fat = 10,
            .fat_count = 2,
        };
        try std.testing.expectEqual(EntryLocation{
            .sector = 1,
            .byte_offset = 0,
        }, boot16.entryLocation(0));
        try std.testing.expectEqual(EntryLocation{
            .sector = 1,
            .byte_offset = 4,
        }, boot16.entryLocation(2));
        try std.testing.expectEqual(EntryLocation{
            .sector = 2,
            .byte_offset = 0,
        }, boot16.entryLocation(256));
        try std.testing.expectEqual(EntryLocation{
            .sector = 2,
            .byte_offset = 2,
        }, boot16.entryLocation(257));

        const boot32: BootSector = .{
            .bytes_per_sector = 512,
            .sectors_per_cluster = 1,
            .first_root_dir_sector = 100,
            .volume_id = 0,
            .volume_label = undefined,
            .type = .fat32,
            .first_data_sector = 200,
            .first_fat_sector = 32,
            .sectors_per_fat = 100,
            .fat_count = 2,
        };
        try std.testing.expectEqual(EntryLocation{
            .sector = 32,
            .byte_offset = 0,
        }, boot32.entryLocation(0));
        try std.testing.expectEqual(EntryLocation{
            .sector = 32,
            .byte_offset = 8,
        }, boot32.entryLocation(2));
        try std.testing.expectEqual(EntryLocation{
            .sector = 33,
            .byte_offset = 0,
        }, boot32.entryLocation(128));

        const boot12: BootSector = .{
            .bytes_per_sector = 512,
            .sectors_per_cluster = 1,
            .first_root_dir_sector = 100,
            .volume_id = 0,
            .volume_label = undefined,
            .type = .fat12,
            .first_data_sector = 200,
            .first_fat_sector = 1,
            .sectors_per_fat = 3,
            .fat_count = 1,
        };
        try std.testing.expectEqual(EntryLocation{
            .sector = 1,
            .byte_offset = 0,
        }, boot12.entryLocation(0));
        try std.testing.expectEqual(EntryLocation{
            .sector = 1,
            .byte_offset = 1,
        }, boot12.entryLocation(1));
        try std.testing.expectEqual(EntryLocation{
            .sector = 1,
            .byte_offset = 3,
        }, boot12.entryLocation(2));
        try std.testing.expectEqual(EntryLocation{
            .sector = 1,
            .byte_offset = 4,
        }, boot12.entryLocation(3));
    }

    pub fn readFrom(src: anytype, sector_offset: u32) !BootSector {
        const r = shared.bytes.wrapWithReader(src);
        const raw = try r.takePtr(Format);
        try raw.signature.toNative().assertValid();

        const is_fat32 = raw.isFat32();
        if (is_fat32) {
            log.info("FAT32 version: {}", .{raw.type.fat32.fs_version.toNative()});
        }

        const bytes_per_sector = try raw.bytesPerSector();
        const sectors_per_cluster = try raw.sectorsPerCluster();

        const reserved_sector_count = try raw.reservedSectorCount();
        const sectors_per_fat = try raw.sectorsPerFat();
        const fat_count = try raw.fatCount();
        const fat_sector_count = sectors_per_fat * fat_count;
        const root_dir_entry_count = try raw.rootDirEntryCount();
        const root_dir_area_sector_count = if (root_dir_entry_count) |n|
            (@sizeOf(DirectoryEntry.Format) * n + bytes_per_sector - 1) / bytes_per_sector
        else
            0;
        const first_fat_sector = reserved_sector_count;
        const first_root_dir_sector = if (is_fat32)
            reserved_sector_count + fat_sector_count + (try raw.fat32RootCluster() - 2) * sectors_per_cluster
        else
            reserved_sector_count + fat_sector_count;
        const first_data_sector = reserved_sector_count + fat_sector_count + root_dir_area_sector_count;

        const total_sector_count = try raw.totalSectorCount();
        if (total_sector_count < first_data_sector) {
            log.err("invalid number of total sectors", .{});
            return error.InvalidFormat;
        }
        const data_sector_count = total_sector_count - first_data_sector;

        const cluster_count = data_sector_count / sectors_per_cluster;
        const fat_type: Type = if (is_fat32) .fat32 else if (cluster_count <= max_fat12_cluster_count) .fat12 else .fat16;

        switch (fat_type) {
            .fat12 => try raw.type.fat12.boot_signature.assertValid(),
            .fat16 => try raw.type.fat16.boot_signature.assertValid(),
            .fat32 => try raw.type.fat32.boot_signature.assertValid(),
        }
        const volume_id, const volume_label = switch (fat_type) {
            .fat12 => .{ raw.type.fat12.volume_id.toNative(), raw.type.fat12.volume_label },
            .fat16 => .{ raw.type.fat16.volume_id.toNative(), raw.type.fat16.volume_label },
            .fat32 => .{ raw.type.fat32.volume_id.toNative(), raw.type.fat32.volume_label },
        };

        return .{
            .bytes_per_sector = bytes_per_sector,
            .sectors_per_cluster = sectors_per_cluster,
            .sectors_per_fat = sectors_per_fat,
            .fat_count = fat_count,
            .first_root_dir_sector = sector_offset + first_root_dir_sector,
            .first_data_sector = sector_offset + first_data_sector,
            .first_fat_sector = sector_offset + first_fat_sector,

            .volume_id = volume_id,
            .volume_label = volume_label,

            .type = switch (fat_type) {
                .fat12 => .fat12,
                .fat16 => .fat16,
                .fat32 => .fat32,
            },
        };
    }

    pub const Format = extern struct {
        comptime {
            std.debug.assert(512 == @sizeOf(Format));
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
        type: extern union {
            fat12: Fat12Or16Specific,
            fat16: Fat12Or16Specific,
            fat32: Fat32Specific,
        },
        signature: Le(Magic(u16, 0xAA55)) align(1),
        // Remaining bytes are filled by 0.

        pub const Fat12Or16Specific = extern struct {
            drive_num: u8,
            _bs_reserved: u8 = 0,
            /// This should be validated before accessing the following 3 fields.
            boot_signature: Magic(u8, 0x29),
            volume_id: Le(u32) align(1),
            volume_label: [11]u8,
            fs_name: [8]u8,
            boot_code: [448]u8,
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
            /// This should be validated before accessing the following 3 fields.
            boot_signature: Magic(u8, 0x29),
            volume_id: Le(u32) align(1),
            volume_label: [11]u8,
            fs_name: [8]u8,
            boot_code: [420]u8,
        };

        pub fn isFat32(self: *const Format) bool {
            return self.fat_size_16.toNative() == 0;
        }

        pub fn bytesPerSector(self: *const Format) !u16 {
            const bytes_per_sector = self.bytes_per_sector.toNative();
            switch (bytes_per_sector) {
                512, 1024, 2048, 4096 => return bytes_per_sector,
                else => {
                    log.err("invalid sector size: {}", .{bytes_per_sector});
                    return error.InvalidFormat;
                },
            }
        }

        pub fn sectorsPerCluster(self: *const Format) !u8 {
            const sectors_per_cluster = self.sectors_per_cluster;
            if (!std.math.isPowerOfTwo(sectors_per_cluster)) {
                log.err("number of sectors per cluster must be power of 2", .{});
                return error.InvalidFormat;
            }
            return sectors_per_cluster;
        }

        pub fn reservedSectorCount(self: *const Format) !u16 {
            const reserved_sector_count = self.reserved_sector_count.toNative();
            if (reserved_sector_count == 0) {
                log.err("number of reserved sectors must not be 0", .{});
                return error.InvalidFormat;
            }
            return reserved_sector_count;
        }

        pub fn sectorsPerFat(self: *const Format) !u32 {
            const fat_size = if (self.isFat32())
                self.type.fat32.fat_size_32.toNative()
            else
                @as(u32, self.fat_size_16.toNative());
            if (fat_size == 0) {
                log.err("FAT size must not be 0", .{});
                return error.InvalidFormat;
            }
            return fat_size;
        }

        pub fn fatCount(self: *const Format) !u8 {
            if (self.fat_count == 0) {
                log.err("number of FATs must not be 0", .{});
                return error.InvalidFormat;
            }
            return self.fat_count;
        }

        pub fn rootDirEntryCount(self: *const Format) !?u16 {
            if (!self.isFat32()) {
                return self.root_entry_count.toNative();
            }
            if (0 < self.root_entry_count.toNative()) {
                log.err("number of root directory entries must no be specified for FAT32", .{});
                return error.InvalidFormat;
            }
            return null;
        }

        pub fn totalSectorCount(self: *const Format) !u32 {
            if (!self.isFat32() and self.total_sectors_32.toNative() == 0) {
                return self.total_sectors_16.toNative();
            }
            if (0 < self.total_sectors_16.toNative()) {
                log.err("16-bit and 32-bit total sectors fields must be used exclusively", .{});
                return error.InvalidFormat;
            }
            return self.total_sectors_32.toNative();
        }

        pub fn fat32RootCluster(self: *const Format) !u32 {
            const root_cluster = self.type.fat32.root_cluster.toNative();
            if (root_cluster < 2) {
                log.err("cluster number must be greater than or equal to 2", .{});
                return error.InvalidFormat;
            }
            return root_cluster;
        }
    };
};

pub const EntryLocation = struct {
    sector: u32,
    byte_offset: u16,
};

pub fn Entry(fat_type: Type) type {
    const ReservedBits, const InnerBits = switch (fat_type) {
        .fat12 => .{ u0, u12 },
        .fat16 => .{ u0, u16 },
        .fat32 => .{ u4, u28 },
    };
    const bad_cluster: InnerBits = switch (fat_type) {
        .fat12 => 0xFF7,
        .fat16 => 0xFFF7,
        .fat32 => 0xFFFFFF7,
    };
    return Le(packed struct(@Int(.unsigned, @bitSizeOf(InnerBits) + @bitSizeOf(ReservedBits))) {
        inner: enum(InnerBits) {
            free = 0,
            _reserved = 1,
            bad_cluster = bad_cluster,
            _,
        },
        _: ReservedBits = 0,

        pub fn isInUse(self: @This()) bool {
            return switch (self.inner) {
                _ => true,
                else => false,
            };
        }

        pub fn nextCluster(self: @This()) ?InnerBits {
            return switch (self.inner) {
                _ => if (@intFromEnum(self.inner) < bad_cluster) @intFromEnum(self.inner) else null,
                else => null,
            };
        }
    });
}

pub const CombinedDirectoryEntry = struct {
    /// ANSI/OEM
    short_name: [11]u8,
    attribute: DirectoryEntry.Format.Attribute,
    first_cluster: u32,
    file_size: u32,
    /// UTF-16LE
    long_name: [255]u16 = undefined,
    long_name_len: usize = 0,

    pub fn readFrom(src: anytype) !?CombinedDirectoryEntry {
        return entry: while (true) {
            const last = switch (try DirectoryEntry.readFrom(src)) {
                .free => break null,
                .removed => continue,
                .short => |short| break .{
                    .short_name = short.name,
                    .attribute = short.attribute,
                    .first_cluster = short.first_cluster,
                    .file_size = short.file_size,
                },
                .long => |long| long,
            };
            if (!last.last) {
                log.warn("last LFN not found", .{});
                continue;
            }
            if (last.seq < 1 or 20 < last.seq) {
                log.warn("invalid LFN sequence number: {}", .{last.seq});
                continue;
            }
            const long_name_len = (last.seq - 1) * 13 + last.getName().len;
            if (255 < long_name_len) {
                log.warn("too long LFN length: {}", .{long_name_len});
                continue;
            }
            var long_name: [255]u16 = undefined;
            @memcpy(long_name[(last.seq - 1) * 13 ..][0..last.getName().len], last.getName());
            const actual_checksum = last.checksum;
            var expected_seq = last.seq - 1;
            while (0 < expected_seq) : (expected_seq -= 1) {
                switch (try DirectoryEntry.readFrom(src)) {
                    .free => {
                        log.warn("free entry in LFN sequence", .{});
                        break :entry null;
                    },
                    .removed => {
                        log.warn("removed entry in LFN sequence", .{});
                        continue :entry;
                    },
                    .long => |long| {
                        if (long.last) {
                            log.warn("unexpected last LFN entry in LFN sequence", .{});
                            continue :entry;
                        }
                        if (long.seq != expected_seq) {
                            log.warn("noncontinguous LFN sequence number: expected {}, got {}", .{
                                expected_seq,
                                long.seq,
                            });
                            continue :entry;
                        }
                        if (long.checksum != actual_checksum) {
                            log.warn("LFN checksum mismatch", .{});
                            continue :entry;
                        }
                        @memcpy(long_name[(long.seq - 1) * 13 ..][0..13], &long.name);
                    },
                    .short => {
                        log.warn("unexpected SFN entry in LFN sequence", .{});
                        continue :entry;
                    },
                }
            }
            switch (try DirectoryEntry.readFrom(src)) {
                .free => {
                    log.warn("SFN not found after LFN", .{});
                    break :entry null;
                },
                .removed => {
                    log.warn("SFN entry was removed", .{});
                    continue :entry;
                },
                .short => |short| {
                    if (short.checksum != actual_checksum) {
                        log.warn("SFN checksum mismatch", .{});
                        continue :entry;
                    }
                    break :entry .{
                        .short_name = short.name,
                        .attribute = short.attribute,
                        .first_cluster = short.first_cluster,
                        .file_size = short.file_size,
                        .long_name = long_name,
                        .long_name_len = long_name_len,
                    };
                },
                .long => {
                    log.warn("unexpected LFN entry while expecting SFN", .{});
                    continue :entry;
                },
            }
        };
    }

    pub fn longName(self: *const CombinedDirectoryEntry) ?[]const u16 {
        if (self.long_name_len == 0) return null;
        return self.long_name[0..self.long_name_len];
    }

    pub fn format(self: CombinedDirectoryEntry, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{f} {B: >12}  {s}", .{ self.attribute, self.file_size, &self.short_name });
        if (self.longName()) |long_name| {
            try w.print(" // {f}", .{std.unicode.fmtUtf16Le(long_name)});
        }
    }
};

pub const DirectoryEntry = union(enum) {
    /// Continuous entries should also be free.
    free,
    removed,
    short: struct {
        name: [11]u8,
        checksum: u8,
        attribute: Format.Attribute,
        first_cluster: u32,
        file_size: u32,
    },
    long: struct {
        /// Encoded in UTF-16LE, and terminated by U+0000 only if the length is less than 13.
        name: [13]u16,
        checksum: u8,
        last: bool,
        seq: u6,

        pub fn getName(self: *const @This()) []const u16 {
            if (!self.last) return &self.name;
            const nul = std.mem.findScalar(u16, &self.name, 0) orelse return &self.name;
            return self.name[0..nul];
        }
    },

    pub fn readFrom(src: anytype) !DirectoryEntry {
        const r = shared.bytes.wrapWithReader(src);
        const raw = try r.takePtr(Format);
        if (raw.isLongFileName()) {
            const first_byte = raw.first_byte.long;
            const long = raw.type.long;
            return .{
                .long = .{
                    .name = @bitCast(raw.name ++ long.name2 ++ long.name3),
                    .checksum = long.checksum,
                    .last = first_byte.last,
                    .seq = first_byte.seq,
                },
            };
        } else {
            const first_byte = raw.first_byte.short;
            const short = raw.type.short;
            var name: [11]u8 = switch (first_byte) {
                .free_entry => return .free,
                .removed_entry => return .removed,
                .replaced => .{0xE5} ++ raw.name,
                _ => .{@intFromEnum(first_byte)} ++ raw.name,
            };
            if (short.nt_reserved.lowercase_body) {
                for (0..8) |i| name[i] = std.ascii.toLower(name[i]);
            }
            if (short.nt_reserved.lowercase_ext) {
                for (8..11) |i| name[i] = std.ascii.toLower(name[i]);
            }
            var checksum: u8 = @intFromEnum(first_byte);
            for (raw.name) |byte| {
                checksum = (checksum >> 1) | (checksum << 7);
                checksum +%= byte;
            }
            return .{
                .short = .{
                    .name = name,
                    .checksum = checksum,
                    .attribute = raw.attribute,
                    .first_cluster = short.firstCluster(),
                    .file_size = short.file_size.toNative(),
                },
            };
        }
    }

    pub const Format = extern struct {
        comptime {
            std.debug.assert(32 == @sizeOf(Format));
        }

        first_byte: FirstByte,
        name: [10]u8,
        attribute: Attribute,
        type: extern union {
            short: extern struct {
                nt_reserved: packed struct(u8) {
                    _0: u3 = 0,
                    lowercase_body: bool,
                    lowercase_ext: bool,
                    _1: u3 = 0,
                },
                create_time_tenth: u8,
                create_time: Le(u16) align(1),
                create_date: Le(u16) align(1),
                last_access_date: Le(u16) align(1),
                first_cluster_high: Le(u16) align(1),
                write_time: Le(u16) align(1),
                write_date: Le(u16) align(1),
                first_cluster_low: Le(u16) align(1),
                file_size: Le(u32) align(1),

                pub fn firstCluster(self: *const @This()) u32 {
                    return (@as(u32, self.first_cluster_high.toNative()) << 16) | self.first_cluster_low.toNative();
                }
            },
            long: extern struct {
                _type: u8 = 0,
                checksum: u8,
                name2: [12]u8,
                _first_cluster_low: Le(u16) align(1) = .fromNative(0),
                name3: [4]u8,
            },
        },

        pub const FirstByte = extern union {
            short: enum(u8) {
                free_entry = 0x00,
                removed_entry = 0xE5,
                /// First byte of the name is 0xE5
                replaced = 0x05,
                /// First byte of the name
                _,
            },
            long: packed struct(u8) {
                /// 1...20
                seq: u6,
                // 0x40 = 0b0100_0000
                last: bool,
                _: u1 = 0,
            },
        };

        pub const Attribute = packed struct(u8) {
            readonly: bool = false,
            hidden: bool = false,
            system: bool = false,
            volume_id: bool = false,
            directory: bool = false,
            archive: bool = false,
            _: u2 = 0,

            pub const long_file_name: Attribute = .{
                .readonly = true,
                .hidden = true,
                .system = true,
                .volume_id = true,
            };

            pub fn format(self: Attribute, w: *std.Io.Writer) std.Io.Writer.Error!void {
                try w.writeAll(&.{
                    if (self.archive) 'a' else '-',
                    if (self.directory) 'd' else '-',
                    if (self.volume_id) 'v' else '-',
                    if (self.system) 's' else '-',
                    if (self.hidden) 'h' else '-',
                    if (self.readonly) 'r' else '-',
                });
            }
        };

        pub fn isLongFileName(self: *const Format) bool {
            return self.attribute == Attribute.long_file_name;
        }
    };
};

comptime {
    std.testing.refAllDecls(@This());
}
