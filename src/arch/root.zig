const builtin = @import("builtin");
const std = @import("std");

pub const riscv = @import("riscv.zig");
pub const Context = riscv.Context;
pub const barrier = riscv.barrier;
pub const trap = riscv.trap;
pub const mmu = switch (builtin.target.cpu.arch) {
    .riscv32, .riscv32be => riscv.mmu.sv32,
    .riscv64, .riscv64be => riscv.mmu.sv39,
    else => void,
};

comptime {
    _ = riscv;
}
