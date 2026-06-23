pub inline fn full() void {
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
}

pub inline fn write() void {
    asm volatile ("fence o, w" ::: .{ .memory = true });
}

pub inline fn read() void {
    asm volatile ("fence i, r" ::: .{ .memory = true });
}
