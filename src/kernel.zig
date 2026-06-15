const builtin = @import("builtin");
const std = @import("std");
const log = std.log.scoped(.kernel);

const shared = @import("shared");

pub const Fdt = @import("Fdt.zig");
pub const Process = @import("Process.zig");
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
        const PageAllocator = shared.heap.BuddyAllocator(.{});

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
        var driver = virtio.init(address) catch |e| switch (e) {
            error.OutOfMemory, error.QueueAlreadyInUse => return e,
            error.InvalidDevice, error.UnsupportedDevice => {
                log.info("skip device {s}", .{fdt_node.name});
                continue;
            },
        } orelse {
            log.debug("ignore device {s}", .{fdt_node.name});
            continue;
        };
        switch (driver) {
            .network => |*virtio_net| {
                defer virtio_net.deinit();

                const default_mac: shared.net.MacAddress = .init(.{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 });
                const source_mac: shared.net.MacAddress = virtio_net.macAddress() orelse default_mac;
                log.info("our MAC address is {f}", .{source_mac});
                const source_ip: shared.net.Ipv4Address = .init(.{ 10, 0, 2, 15 });
                const target_ip: shared.net.Ipv4Address = .init(.{ 10, 0, 2, 2 });

                var bump: shared.heap.PagedBumpAllocator = .init;
                defer bump.deinit();

                var send_buf: shared.bytes.alloc.Writable = .init(bump.allocator());
                defer send_buf.deinit();
                var recv_buf: shared.bytes.alloc.Writable = .init(bump.allocator());
                defer recv_buf.deinit();

                const resolved_mac: shared.net.MacAddress = b: {
                    defer send_buf.clear();
                    const arp_frame: shared.net.ArpFrame = .{
                        .source_mac = source_mac,
                        .target_mac = .broadcast,
                        .source_ip = source_ip,
                        .target_ip = target_ip,
                    };
                    try arp_frame.writeInto(&send_buf);
                    log.info("sending ARP request for {f}", .{target_ip});
                    virtio_net.sendFrame(send_buf.written());

                    while (true) {
                        recv_buf.clear();
                        try virtio_net.receiveFrame(&recv_buf);
                        var frame: shared.bytes.fixed.Readable = .init(recv_buf.written());
                        var arp_reply = try shared.net.ArpFrame.readFrom(&frame) orelse continue;
                        if (!std.mem.eql(u8, &arp_reply.target_ip.octets, &source_ip.octets)) continue;
                        break :b arp_reply.source_mac;
                    }
                };

                {
                    defer send_buf.clear();
                    const icmp_req: shared.net.IcmpEchoFrame = .{
                        .source_mac = source_mac,
                        .target_mac = resolved_mac,
                        .source_ip = source_ip,
                        .target_ip = target_ip,
                        .identifier = 0x1234,
                        .sequence = 1,
                        .data = "hello world",
                    };
                    try icmp_req.writeInto(&send_buf);
                    log.info("sending ICMP echo request to {f}", .{target_ip});
                    virtio_net.sendFrame(send_buf.written());

                    const icmp_data = while (true) {
                        recv_buf.clear();
                        try virtio_net.receiveFrame(&recv_buf);
                        var frame: shared.bytes.fixed.Readable = .init(recv_buf.written());
                        const icmp_reply = try shared.net.IcmpEchoFrame.readFrom(&frame) orelse continue;
                        if (icmp_reply.identifier != 0x1234 or icmp_reply.sequence != 1) continue;
                        break icmp_reply.data;
                    };
                    log.info("ICMP echo reply received: {s}", .{icmp_data});
                }
            },
            .block => |*virtio_blk| {
                defer virtio_blk.deinit();
                log.info("writing message in {s}", .{fdt_node.name});
                var buf = std.mem.zeroes([512]u8);
                try virtio_blk.request(.read, &buf, 0);
                @memcpy(buf[0..].ptr, "hello world!");
                try virtio_blk.request(.write, &buf, 0);
            },
        }
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
}
