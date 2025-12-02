const std = @import("std");
const log = std.log.scoped(.kernel);

pub const panic = blk: {
    break :blk std.debug.FullPanic(struct {
        fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
            @branchHint(.cold);
            _ = first_trace_addr;
            log.err("PANIC: {s}", .{msg});
            // _ = sbi.system.reset(.shutdown, .system_failure);
            while (true) asm volatile ("wfi");
        }
    }.panic);
};

pub const std_options: std.Options = blk: {
    const funcs = struct {
        fn logFn(
            comptime level: std.log.Level,
            comptime scope: @Type(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            const level_text = comptime level.asText();
            const scope_text = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
            var writer = sbi.console.writer();
            writer.print(level_text ++ scope_text ++ format ++ "\n", args) catch {};
        }
    };
    break :blk .{
        .logFn = funcs.logFn,
    };
};

// idk why, but `extern` keyword doesn't work properly
const bss = @extern([*]u8, .{ .name = "__bss" });
const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
const stack_top = @extern([*]u8, .{ .name = "__stack_top" });

export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ mv sp, %[stack_top]
        \\ j kernelMain
        :
        : [stack_top] "r" (stack_top),
    );
}

export fn kernelMain() noreturn {
    @memset(bss[0 .. @intFromPtr(bss_end) - @intFromPtr(bss)], 0);

    writeCsr(.stvec, @intFromPtr(&kernelEntry));

    sbi.console.putChar('\n');

    var fba = ram.fixedBufferAllocator();
    const pt_allocator = fba.allocator();
    Process.initGlobal(pt_allocator);
    _ = Process.create(@intFromPtr(&procAEntry), pt_allocator);
    _ = Process.create(@intFromPtr(&procBEntry), pt_allocator);
    Process.yield();

    log.debug("shutting down...", .{});
    _ = sbi.system.reset(.shutdown, .no_reason);
    unreachable;
}

fn delay() void {
    for (0..30000000) |_| {
        asm volatile ("nop");
    }
}

fn procAEntry() void {
    log.debug("starting process A", .{});
    while (true) {
        sbi.console.putChar('A');
        Process.yield();
        delay();
    }
}

fn procBEntry() void {
    log.debug("starting process B", .{});
    while (true) {
        sbi.console.putChar('B');
        Process.yield();
        delay();
    }
}

const Process = struct {
    state: State,
    pid: usize,
    sp: *u8,
    page_table: *sv32.PageTable,
    stack: [8192]u8 align(@alignOf(usize)),

    const State = enum { unused, runnable };

    const Self = @This();

    var buf: [8]Process = undefined;
    var pool: std.ArrayList(Process) = .initBuffer(&buf);

    fn create(
        pc: usize,
        /// only used for allocating page tables
        pt_allocator: std.mem.Allocator,
    ) *Self {
        const proc: *Process = blk: for (pool.items) |*p| {
            if (p.state == .unused) break :blk p;
        } else {
            pool.appendBounded(.{
                .state = .unused,
                .pid = pool.items.len,
                .sp = undefined,
                .page_table = undefined,
                .stack = undefined,
            }) catch @panic("no free process slots");
            break :blk &pool.items[pool.items.len - 1];
        };

        proc.state = .runnable;
        //  | ...
        //  |-----> proc.sp
        //  | pc    // -> ra
        //  |-----
        //  | 0     // -> s0
        //  |-----
        //  | 0     // -> s1 .. s10
        //  |-----
        //  | 0     // -> s11
        //  `-----
        const casted_stack = blk: {
            var ptr: [*]usize = @ptrCast(&proc.stack);
            break :blk ptr[0 .. proc.stack.len * @sizeOf(u8) / @sizeOf(usize)];
        };
        casted_stack[casted_stack.len - 13] = pc;
        for (casted_stack.len - 12..casted_stack.len) |i| {
            casted_stack[i] = 0;
        }
        proc.sp = @ptrCast(&casted_stack[casted_stack.len - 13]);

        const page_table: *sv32.PageTable = .init(pt_allocator);
        page_table.mapKernelPage(pt_allocator);
        proc.page_table = page_table;

        return proc;
    }

    fn switchContext(self: *Self, next: *Self) void {
        asm volatile ("jalr %[inner]"
            :
            : [self] "{a0}" (self),
              [next] "{a1}" (next),
              [inner] "r" (&switchContextInner),
            : .{ .x1 = true }); // ra
    }

    fn switchContextInner(
        // self: *Self,
        // next: *Self,
    ) callconv(.naked) noreturn {
        asm volatile (
            \\
            // | ...
            // |-----> sp
            // | <- ra
            // |-----
            // | <- s0
            // |-----
            // | <- s1 .. s10
            // |-----
            // | <- s11
            // |-----> prev sp
            // | ...
            \\ addi sp, sp, -13 * 4
            \\ sw ra,  0  * 4(sp)
            \\ sw s0,  1  * 4(sp)
            \\ sw s1,  2  * 4(sp)
            \\ sw s2,  3  * 4(sp)
            \\ sw s3,  4  * 4(sp)
            \\ sw s4,  5  * 4(sp)
            \\ sw s5,  6  * 4(sp)
            \\ sw s6,  7  * 4(sp)
            \\ sw s7,  8  * 4(sp)
            \\ sw s8,  9  * 4(sp)
            \\ sw s9,  10 * 4(sp)
            \\ sw s10, 11 * 4(sp)
            \\ sw s11, 12 * 4(sp)

            // self.sp = sp
            \\ sw sp, %[sp_offset](a0)
            // sp = next.sp
            \\ lw sp, %[sp_offset](a1)

            // | ...
            // |-----> next.sp
            // | -> ra
            // |-----
            // | -> s0
            // |-----
            // | -> s1 .. s10
            // |-----
            // | -> s11
            // |-----> sp
            // | ...
            \\ lw ra,  0  * 4(sp)
            \\ lw s0,  1  * 4(sp)
            \\ lw s1,  2  * 4(sp)
            \\ lw s2,  3  * 4(sp)
            \\ lw s3,  4  * 4(sp)
            \\ lw s4,  5  * 4(sp)
            \\ lw s5,  6  * 4(sp)
            \\ lw s6,  7  * 4(sp)
            \\ lw s7,  8  * 4(sp)
            \\ lw s8,  9  * 4(sp)
            \\ lw s9,  10 * 4(sp)
            \\ lw s10, 11 * 4(sp)
            \\ lw s11, 12 * 4(sp)
            \\ addi sp, sp, 13 * 4
            \\ ret
            :
            : [sp_offset] "I" (@offsetOf(Self, "sp")),
            : .{ .memory = true });
    }

    var current: *Self = undefined;
    var idle: *Self = undefined;

    fn initGlobal(pt_allocator: std.mem.Allocator) void {
        idle = create(0, pt_allocator);
        current = idle;
    }

    fn yield() void {
        const current_idx = (@intFromPtr(current) - @intFromPtr(&pool.items)) / @sizeOf(Self);
        const next: *Self = for (current_idx + 1..current_idx + pool.items.len) |i| {
            const proc = &pool.items[i % pool.items.len];
            if (proc.state == .runnable and proc != idle) break proc;
        } else {
            return;
        };
        asm volatile (
            \\ sfence.vma
            \\ csrw satp, %[satp]
            \\ sfence.vma
            \\ csrw sscratch, %[sscratch]
            :
            : [satp] "r" (next.page_table.getSatpValue()),
              [sscratch] "r" (@intFromPtr(&next.stack) + @sizeOf(u8) * next.stack.len),
        );
        const prev = current;
        current = next;
        prev.switchContext(next);
    }
};

const sv32 = struct {
    const Satp = packed struct(u32) {
        ppn: u22,
        asid: u9 = 0,
        mode: u1 = 1,
    };

    const kernel_page = @extern([*]usize, .{ .name = "__kernel_page" });
    const kernel_page_end = @extern([*]usize, .{ .name = "__kernel_page_end" });

    const PageTable = struct {
        entries: [entry_count]Entry,

        const entry_count = (1 << 12) / @sizeOf(Entry);

        fn init(a: std.mem.Allocator) *PageTable {
            const entries = a.alignedAlloc(
                Entry,
                .fromByteUnits(@sizeOf(PageTable)),
                entry_count,
            ) catch @panic("OOM");
            return @ptrCast(entries.ptr);
        }

        fn getSatpValue(self: *const PageTable) Satp {
            return .{
                .ppn = @truncate(@intFromPtr(self) / @sizeOf(PageTable)),
            };
        }

        fn getAddr(self: *PageTable) PhysAddr {
            return @bitCast(@as(u34, @intCast(@intFromPtr(self))));
        }

        fn fromAddr(paddr: PhysAddr) *PageTable {
            return @ptrFromInt(@as(usize, @truncate(@as(u34, @bitCast(paddr)))));
        }

        fn mapKernelPage(table1: *PageTable, a: std.mem.Allocator) void {
            var paddr = @intFromPtr(kernel_page);
            while (paddr < @intFromPtr(kernel_page_end)) : (paddr += @sizeOf(PageTable)) {
                table1.mapPage(
                    a,
                    @bitCast(paddr),
                    @bitCast(@as(u34, @intCast(paddr))),
                    .{ .readable = true, .writable = true, .executable = true },
                );
            }
        }

        fn mapPage(
            table1: *PageTable,
            a: std.mem.Allocator,
            virt_addr: VirtAddr,
            phys_addr: PhysAddr,
            flags: Entry.Flags,
        ) void {
            std.debug.assert(virt_addr.offset == 0);
            const entry1 = &table1.entries[@intCast(virt_addr.vpn1)];
            if (!entry1.flags.valid) {
                const table0: *PageTable = .init(a);
                entry1.* = .init(table0.getAddr(), .{});
            }
            const table0: *PageTable = .fromAddr(entry1.getAddr());
            const entry0 = &table0.entries[@intCast(virt_addr.vpn0)];
            entry0.* = .init(phys_addr, flags);
        }

        const Entry = packed struct(u32) {
            flags: Flags,
            ppn0: u10,
            ppn1: u12,

            const Flags = packed struct {
                valid: bool = true,
                readable: bool = false,
                writable: bool = false,
                executable: bool = false,
                usermode: bool = false,
                global: bool = false,
                accessed: bool = false,
                dirty: bool = false,
                _: u2 = 0,
            };

            fn init(paddr: PhysAddr, flags: Flags) Entry {
                std.debug.assert(paddr.offset == 0);
                return .{
                    .flags = flags,
                    .ppn0 = paddr.ppn0,
                    .ppn1 = paddr.ppn1,
                };
            }

            fn getAddr(self: Entry) PhysAddr {
                return .{
                    .offset = 0,
                    .ppn0 = self.ppn0,
                    .ppn1 = self.ppn1,
                };
            }
        };
    };

    const VirtAddr = packed struct(u32) {
        offset: u12,
        vpn0: u10,
        vpn1: u10,
    };

    const PhysAddr = packed struct(u34) {
        offset: u12,
        ppn0: u10,
        ppn1: u12,
    };
};

const ram = struct {
    const free_ram = @extern([*]u8, .{ .name = "__free_ram" });
    const free_ram_end = @extern([*]u8, .{ .name = "__free_ram_end" });

    fn fixedBufferAllocator() std.heap.FixedBufferAllocator {
        const buf = free_ram[0 .. @intFromPtr(free_ram_end) - @intFromPtr(free_ram)];
        return .init(buf);
    }
};

const sbi = struct {
    const Ret = struct {
        err: usize,
        val: usize,
    };

    fn call(
        arg0: usize,
        arg1: usize,
        arg2: usize,
        arg3: usize,
        arg4: usize,
        arg5: usize,
        fid: usize,
        eid: usize,
    ) Ret {
        var err = arg0;
        var val = arg1;
        asm volatile (
            \\ ecall
            : [r0] "={a0}" (err),
              [r1] "={a1}" (val),
            : [a0] "{a0}" (arg0),
              [a1] "{a1}" (arg1),
              [a2] "{a2}" (arg2),
              [a3] "{a3}" (arg3),
              [a4] "{a4}" (arg4),
              [a5] "{a5}" (arg5),
              [a6] "{a6}" (fid),
              [a7] "{a7}" (eid),
            : .{ .memory = true });
        return .{
            .err = err,
            .val = val,
        };
    }

    const system = struct {
        const ResetType = enum(u32) {
            shutdown = 0x00,
            cold_reboot = 0x01,
            warm_reboot = 0x02,
            _,
        };

        const ResetReason = enum(u32) {
            no_reason = 0x00,
            system_failure = 0x01,
            _,
        };

        fn reset(ty: ResetType, reason: ResetReason) Ret {
            return call(@intFromEnum(ty), @intFromEnum(reason), 0, 0, 0, 0, 0, 0x53525354);
        }
    };

    const console = struct {
        fn putChar(char: u8) void {
            _ = call(@intCast(char), 0, 0, 0, 0, 0, 0, 1);
        }

        fn writer() std.Io.Writer {
            return .{
                .buffer = &.{},
                .vtable = &.{
                    .drain = drain,
                    .flush = std.Io.Writer.noopFlush,
                },
            };
        }

        fn drain(_: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            var written: usize = 0;
            for (data) |bytes| {
                written += bytes.len;
                for (bytes) |char| putChar(char);
            }
            const last = data[data.len - 1];
            written += last.len * (splat - 1);
            for (0..(splat - 1)) |_| {
                for (last) |char| putChar(char);
            }
            return written;
        }
    };
};

inline fn readCsr(comptime reg: @Type(.enum_literal)) usize {
    return asm volatile ("csrr %[ret], " ++ @tagName(reg)
        : [ret] "=r" (-> usize),
    );
}

inline fn writeCsr(comptime reg: @Type(.enum_literal), value: usize) void {
    asm volatile ("csrw " ++ @tagName(reg) ++ ", %[value]"
        :
        : [value] "r" (value),
    );
}

fn kernelEntry() align(4) callconv(.naked) noreturn {
    asm volatile (
        \\ csrrw sp, sscratch, sp
        \\
        \\ addi sp, sp, -4 * 31
        \\ sw ra,  4 * 0(sp)
        \\ sw gp,  4 * 1(sp)
        \\ sw tp,  4 * 2(sp)
        \\ sw t0,  4 * 3(sp)
        \\ sw t1,  4 * 4(sp)
        \\ sw t2,  4 * 5(sp)
        \\ sw t3,  4 * 6(sp)
        \\ sw t4,  4 * 7(sp)
        \\ sw t5,  4 * 8(sp)
        \\ sw t6,  4 * 9(sp)
        \\ sw a0,  4 * 10(sp)
        \\ sw a1,  4 * 11(sp)
        \\ sw a2,  4 * 12(sp)
        \\ sw a3,  4 * 13(sp)
        \\ sw a4,  4 * 14(sp)
        \\ sw a5,  4 * 15(sp)
        \\ sw a6,  4 * 16(sp)
        \\ sw a7,  4 * 17(sp)
        \\ sw s0,  4 * 18(sp)
        \\ sw s1,  4 * 19(sp)
        \\ sw s2,  4 * 20(sp)
        \\ sw s3,  4 * 21(sp)
        \\ sw s4,  4 * 22(sp)
        \\ sw s5,  4 * 23(sp)
        \\ sw s6,  4 * 24(sp)
        \\ sw s7,  4 * 25(sp)
        \\ sw s8,  4 * 26(sp)
        \\ sw s9,  4 * 27(sp)
        \\ sw s10, 4 * 28(sp)
        \\ sw s11, 4 * 29(sp)
        \\
        \\ csrr a0, sscratch
        \\ sw a0,  4 * 30(sp)
        \\
        \\ addi a0, sp, 4 * 31
        \\ csrw sscratch, a0
        \\
        \\ mv a0, sp
        \\ call handleTrap
        \\
        \\ lw ra,  4 * 0(sp)
        \\ lw gp,  4 * 1(sp)
        \\ lw tp,  4 * 2(sp)
        \\ lw t0,  4 * 3(sp)
        \\ lw t1,  4 * 4(sp)
        \\ lw t2,  4 * 5(sp)
        \\ lw t3,  4 * 6(sp)
        \\ lw t4,  4 * 7(sp)
        \\ lw t5,  4 * 8(sp)
        \\ lw t6,  4 * 9(sp)
        \\ lw a0,  4 * 10(sp)
        \\ lw a1,  4 * 11(sp)
        \\ lw a2,  4 * 12(sp)
        \\ lw a3,  4 * 13(sp)
        \\ lw a4,  4 * 14(sp)
        \\ lw a5,  4 * 15(sp)
        \\ lw a6,  4 * 16(sp)
        \\ lw a7,  4 * 17(sp)
        \\ lw s0,  4 * 18(sp)
        \\ lw s1,  4 * 19(sp)
        \\ lw s2,  4 * 20(sp)
        \\ lw s3,  4 * 21(sp)
        \\ lw s4,  4 * 22(sp)
        \\ lw s5,  4 * 23(sp)
        \\ lw s6,  4 * 24(sp)
        \\ lw s7,  4 * 25(sp)
        \\ lw s8,  4 * 26(sp)
        \\ lw s9,  4 * 27(sp)
        \\ lw s10, 4 * 28(sp)
        \\ lw s11, 4 * 29(sp)
        \\ lw sp,  4 * 30(sp)
        \\ sret
    );
}

export fn handleTrap(frame: *TrapFrame) void {
    _ = frame;
    const scause = readCsr(.scause);
    const stval = readCsr(.stval);
    const user_pc = readCsr(.sepc);
    std.debug.panic("unexpected trap: scause={x}, stval={x}, sepc={x}", .{ scause, stval, user_pc });
}

const TrapFrame = packed struct {
    ra: usize,
    gp: usize,
    tp: usize,
    t0: usize,
    t1: usize,
    t2: usize,
    t3: usize,
    t4: usize,
    t5: usize,
    t6: usize,
    a0: usize,
    a1: usize,
    a2: usize,
    a3: usize,
    a4: usize,
    a5: usize,
    a6: usize,
    a7: usize,
    s0: usize,
    s1: usize,
    s2: usize,
    s3: usize,
    s4: usize,
    s5: usize,
    s6: usize,
    s7: usize,
    s8: usize,
    s9: usize,
    s10: usize,
    s11: usize,
    sp: usize,
};
