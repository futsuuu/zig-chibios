pub const MemMapEntry = struct {
    base: usize,
    size: usize,
};

// https://gitlab.com/qemu-project/qemu/-/blob/2257f52a/hw/riscv/virt.c#L82

pub const virt_virtio: MemMapEntry = .{
    .base = 0x10001000,
    .size = 0x1000,
};
