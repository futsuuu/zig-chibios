const std = @import("std");

const sxlen = @bitSizeOf(usize);

fn Register(name: @Type(.enum_literal), T: type) type {
    return struct {
        pub const Format = if (hasDecl("Format")) T.Format else T;

        pub inline fn read() T {
            return decode(asm volatile ("csrr %[ret], " ++ @tagName(name)
                : [ret] "=r" (-> Format),
            ));
        }
        pub inline fn write(value: T) void {
            asm volatile ("csrw " ++ @tagName(name) ++ ", %[value]"
                :
                : [value] "r" (encode(value)),
            );
        }

        inline fn encode(value: T) Format {
            return if (comptime hasDecl("encode")) T.encode(value) else value;
        }
        inline fn decode(value: Format) T {
            return if (comptime hasDecl("decode")) T.decode(value) else value;
        }

        fn hasDecl(field: []const u8) bool {
            return switch (@typeInfo(T)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, field),
                else => false,
            };
        }
    };
}

fn UInt(bit_count: u16) type {
    return std.meta.Int(.unsigned, bit_count);
}

fn formatEnum(ptr: anytype, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const self = ptr.*;
    try writer.print(".{s} = {}", .{
        std.enums.tagName(@TypeOf(self), self) orelse "_",
        @intFromEnum(self),
    });
}

/// Supervisor Address Translation and Protection
pub const satp = Register(.satp, packed struct(u32) {
    /// (WARL)
    phys_page_num: u22,
    /// (WARL)
    addr_space_id: u9,
    /// (WARL)
    mode: enum(u1) {
        bare = 0,
        sv32 = 1,
    },
});

/// Supervisor Cause
pub const scause = Register(.scause, union(enum) {
    interrupt: Interrupt,
    exception: Exception,

    /// 16-... is designated for platform use.
    /// (WLRL)
    const Interrupt = enum(UInt(sxlen - 1)) {
        supervisor_software = 1,
        supervisor_timer = 5,
        supervisor_external = 9,
        counter_overflow = 13,
        _,
        pub const format = formatEnum;
    };
    /// 24-31 and 48-63 are designated for custom use.
    /// (WLRL)
    const Exception = enum(UInt(sxlen - 1)) {
        instruction_addr_misaligned = 0,
        instruction_access_fault = 1,
        illegal_instruction = 2,
        breakpoint = 3,
        load_addr_misaligned = 4,
        load_access_fault = 5,
        store_amo_addr_misaligned = 6,
        store_amo_access_fault = 7,
        ecall_from_umode = 8,
        ecall_from_smode = 9,
        instruction_page_fault = 12,
        load_page_fault = 13,
        store_amo_page_fault = 15,
        software_check = 18,
        hardware_error = 19,
        _,
        pub const format = formatEnum;
    };

    const Format = packed struct {
        /// (WLRL)
        code: packed union {
            interrupt: Interrupt,
            exception: Exception,
        },
        is_interrupt: bool,
    };
    fn encode(self: @This()) Format {
        return switch (self) {
            .interrupt => |c| .{
                .code = .{ .interrupt = c },
                .is_interrupt = true,
            },
            .exception => |c| .{
                .code = .{ .exception = c },
                .is_interrupt = false,
            },
        };
    }
    fn decode(value: Format) @This() {
        return if (value.is_interrupt)
            .{ .interrupt = value.code.interrupt }
        else
            .{ .exception = value.code.exception };
    }
});

/// Supervisor Exception Program Counter
pub const sepc = Register(.sepc, usize);

/// Supervisor Scratch
pub const sscratch = Register(.sscratch, usize);

/// Supervisor Trap Value
pub const stval = Register(.stval, usize);

/// Supervisor Trap Vector Base Address
pub const stvec = Register(.stvec, struct {
    /// (WARL)
    mode: Mode,
    /// (WARL)
    ptr: *align(4) const anyopaque,

    pub const Mode = enum(u2) {
        direct = 0,
        vectored = 1,
        _,
    };

    const Format = packed struct(usize) {
        mode: Mode,
        base_addr: UInt(sxlen - 2),
    };

    fn encode(self: @This()) Format {
        return @bitCast(@intFromPtr(self.ptr) + @intFromEnum(self.mode));
    }
    test encode {
        try std.testing.expect(std.meta.eql(
            Format{ .mode = .vectored, .base_addr = 0x12340 >> 2 },
            encode(.{ .mode = .vectored, .ptr = @ptrFromInt(0x12340) }),
        ));
    }

    fn decode(value: Format) @This() {
        return .{
            .mode = value.mode,
            .ptr = @ptrFromInt(@as(usize, value.base_addr) << @bitSizeOf(Mode)),
        };
    }
    test decode {
        try std.testing.expect(std.meta.eql(
            @This(){ .mode = .vectored, .ptr = @ptrFromInt(0x12340) },
            decode(.{ .mode = .vectored, .base_addr = 0x12340 >> 2 }),
        ));
    }
});
