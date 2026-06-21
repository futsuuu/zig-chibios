const root = @import("root");
const std = @import("std");
const page_size = std.heap.pageSize();

const arch = @import("../root.zig");

const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern(*align(arch.stack_unit_size) u8, .{ .name = "__stack_top" });
const kernel_page = @extern([*]align(page_size) [page_size]u8, .{ .name = "__kernel_page" });
const kernel_page_end = @extern([*]align(page_size) [page_size]u8, .{ .name = "__kernel_page_end" });
const free_ram = @extern([*]u8, .{ .name = "__free_ram" });
const free_ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });

pub const Memory = struct {
    kernel_page: []align(page_size) [page_size]u8,
    free_ram: []u8,
};

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ mv sp, %[stack_top]
        \\ j kernelMain
        :
        : [stack_top] "r" (stack_top),
    );
}

/// https://docs.kernel.org/arch/riscv/boot.html
export fn kernelMain(hartid: usize, devicetree_addr: usize) callconv(.c) noreturn {
    @memset(bss[0 .. bss_end - bss], 0);
    arch.trap.initHandler();
    arch.trap.saveCurrentKernelStack(stack_top);
    const mem: Memory = .{
        .kernel_page = kernel_page[0 .. kernel_page_end - kernel_page],
        .free_ram = free_ram[0 .. free_ram_end - free_ram],
    };
    const res = root.main(hartid, devicetree_addr, mem);
    switch (@TypeOf(res)) {
        void => {},
        else => |Result| {
            std.debug.assert(@typeInfo(Result) == .error_union);
            res catch |e| {
                std.debug.panic("root.main() returns {}", .{e});
            };
        },
    }
    while (true) asm volatile ("wfi");
}
