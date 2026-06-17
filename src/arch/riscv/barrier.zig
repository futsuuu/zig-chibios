pub inline fn full() void {
    asm volatile ("fence rw, rw" ::: .{ .memory = true });
}

pub inline fn write() void {
    asm volatile ("fence rw, w" ::: .{ .memory = true });
}
