const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.kernel);

pub const Fdt = @import("Fdt.zig");
pub const Process = @import("Process.zig");
pub const buddy_allocator = @import("buddy_allocator.zig");
pub const sbi = @import("sbi.zig");
pub const sv32 = @import("sv32.zig");
pub const trap = @import("trap.zig");
pub const virtio = @import("virtio.zig");

comptime {
    _ = @import("start.zig");
}

pub const panic = std.debug.FullPanic(struct {
    fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
        @branchHint(.cold);
        printPanicInfo(msg, first_trace_addr);
        while (true) asm volatile ("wfi");
    }
}.panic);

pub const std_options: std.Options = .{
    .page_size_min = sv32.page_size,
    .page_size_max = sv32.page_size,
};

pub const std_options_debug_io: std.Io = .{
    .userdata = null,
    .vtable = &debug_vtable,
};

const debug_vtable: std.Io.VTable = blk: {
    var vtable: std.Io.VTable = std.Io.failing.vtable.*;
    vtable.swapCancelProtection = debugSwapCancelProtection;
    vtable.lockStderr = debugLockStderr;
    vtable.unlockStderr = debugUnlockStderr;
    break :blk vtable;
};

var debug_file_writer: std.Io.File.Writer = .{
    .io = undefined,
    .file = .{
        .handle = {},
        .flags = .{ .nonblocking = false },
    },
    .interface = sbi.debug_console.writer(),
};

fn debugSwapCancelProtection(_: ?*anyopaque, _: std.Io.CancelProtection) std.Io.CancelProtection {
    return .blocked;
}

fn debugLockStderr(_: ?*anyopaque, terminal_mode: ?std.Io.Terminal.Mode) std.Io.Cancelable!std.Io.LockedStderr {
    return .{
        .file_writer = &debug_file_writer,
        .terminal_mode = terminal_mode orelse .escape_codes,
    };
}

fn debugUnlockStderr(_: ?*anyopaque) void {
    debug_file_writer.interface.flush() catch {};
    debug_file_writer.interface.buffer = &.{};
}

pub const os = struct {
    pub const heap = struct {
        const PageAllocator = buddy_allocator.BuddyAllocator(.{});

        pub fn initPageAllocator() std.mem.Allocator.Error!void {
            const free_ram = @extern([*]u8, .{ .name = "__free_ram" });
            const free_ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });
            const buf = free_ram[0 .. free_ram_end - free_ram];
            instance = try .init(buf);
        }

        var instance: PageAllocator = undefined;
        pub const page_allocator: std.mem.Allocator = .{
            .ptr = &instance,
            .vtable = &PageAllocator.vtable,
        };
    };
};

pub fn printPanicInfo(msg: []const u8, first_trace_addr: ?usize) void {
    @branchHint(.cold);
    log.err("PANIC: {s}", .{msg});
    _ = first_trace_addr;
    // FIXME: replace StackIterator with captureCurrentStackTrace
    // var iter: std.debug.StackIterator = .init(first_trace_addr, null);
    // var index: usize = 0;
    // while (iter.next()) |addr| : (index += 1) {
    //     switch (builtin.target.ptrBitWidth()) {
    //         32 => log.err("{:0>3}: 0x{x:0>8}", .{ index, addr }),
    //         64 => log.err("{:0>3}: 0x{x:0>16}", .{ index, addr }),
    //         else => unreachable,
    //     }
    // }
}

var scheduler: Process.Scheduler = undefined;

pub fn main(hartid: usize, devicetree_addr: usize) !void {
    _ = hartid;
    defer log.info("exit", .{});
    std.debug.print("\n", .{});

    try os.heap.initPageAllocator();

    const fdt: Fdt = try .init(devicetree_addr);
    var fdt_nodes = try fdt.nodes();
    while (try fdt_nodes.next()) |fdt_node| {
        if (!fdt_node.isCompatibleWith("virtio,mmio")) {
            continue;
        }
        var registers = fdt_node.registers() orelse {
            log.warn("{s} does not have a reg property", .{fdt_node.name});
            continue;
        };
        const address: usize = @truncate(registers.next().?.address());
        var virtq = try virtio.init(std.heap.page_allocator, address) orelse {
            log.info("skip initialization of device {s}", .{fdt_node.name});
            continue;
        };
        log.info("writing message in {s}", .{fdt_node.name});
        var buf = std.mem.zeroes([512]u8);
        try virtio.request(&virtq, .read, &buf, 0);
        @memcpy(buf[0..].ptr, "hello world!");
        try virtio.request(&virtq, .write, &buf, 0);
    }

    scheduler = try .init(std.heap.page_allocator);
    _ = try scheduler.spawn(&procAEntry, 8192);
    _ = try scheduler.spawn(&procBEntry, 8192);
    scheduler.yield();
}

fn delay() void {
    for (0..30000000) |_| {
        std.atomic.spinLoopHint();
    }
}

fn procAEntry() void {
    log.debug("starting process A", .{});
    var counter: usize = 0;
    while (true) : (counter += 1) {
        std.debug.print("A", .{});
        scheduler.yield();
        delay();
        if (counter == 20) scheduler.exit();
    }
}

fn procBEntry() void {
    log.debug("starting process B", .{});
    while (true) {
        std.debug.print("B", .{});
        scheduler.yield();
        delay();
    }
}

comptime {
    std.testing.refAllDecls(@This());
    _ = @import("PagedBumpAllocator.zig");
}
