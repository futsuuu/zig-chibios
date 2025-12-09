pub const Config = extern struct {
    capacity: u64,
};

pub const Features = enum(u32) {
    size_max = 1,
    seg_max = 2,
    geometry = 4,
    readonly = 5,
    block_size = 6,
    flush = 9,
    topology = 10,
    config_wce = 11,
    multiqueue = 12,
    discard = 13,
    write_zeroes = 14,
    lifetime = 15,
    secure_erase = 16,
    zoned = 17,
};
