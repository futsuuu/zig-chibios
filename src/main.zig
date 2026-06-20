const std = @import("std");
const log = std.log.scoped(.kernel);

const arch = @import("arch");
const kernel = @import("kernel");
const shared = @import("shared");
const virtio = @import("virtio");

pub const debug = kernel.debug;
pub const panic = kernel.panic;
pub const std_options = kernel.std_options;
pub const std_options_debug_io = kernel.std_options_debug_io;
pub const os = struct {
    pub const heap = struct {
        var page_allocator_instance: shared.heap.BuddyAllocator(.{}) = undefined;
        pub const page_allocator: std.mem.Allocator = .{
            .ptr = &page_allocator_instance,
            .vtable = &shared.heap.BuddyAllocator(.{}).vtable,
        };
    };
};

var scheduler: kernel.Process.Scheduler = undefined;

comptime {
    _ = arch.riscv.kernel;
}

pub fn main(hartid: usize, devicetree_addr: usize, mem: arch.riscv.kernel.Memory) !void {
    _ = hartid;
    defer log.info("exit", .{});

    os.heap.page_allocator_instance = try .init(mem.free_ram);

    const fdt: shared.Fdt = try .init(devicetree_addr);
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
                var buf = std.mem.zeroes([512]u8);
                try virtio_blk.request(.read, &buf, 0);
                const mbr: *const shared.partition.Mbr = @ptrCast(&buf);
                for (mbr.partitions, 0..) |part, i| {
                    if (part.type == .free) continue;
                    try virtio_blk.request(.read, &buf, part.offset.toNative());
                    if (!part.type.isFat()) continue;
                    const bootsector: *const shared.fat.BootSector = @ptrCast(&buf);
                    log.debug("{}: FAT type: {}", .{ i, bootsector.detectType() });
                }
            },
        }
    }

    scheduler = try .init(std.heap.page_allocator, mem.kernel_page);
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
