const builtin = @import("builtin");
const std = @import("std");

pub const riscv = @import("riscv.zig");
pub const Context = riscv.Context;
pub const barrier = riscv.barrier;
pub const trap = riscv.trap;

pub const mmu = switch (builtin.cpu.arch) {
    .riscv32, .riscv32be => riscv.mmu.sv32,
    .riscv64, .riscv64be => riscv.mmu.sv39,
    else => void,
};

pub const stack_unit_size = switch (builtin.cpu.arch) {
    .riscv32, .riscv32be, .riscv64, .riscv64be => 16,
    else => unreachable,
};

comptime {
    _ = riscv;
}
