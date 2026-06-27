const std = @import("std");

const SelfInfo = @This();

_: void = {},

pub const init: SelfInfo = .{};

pub fn deinit(si: *SelfInfo, io: std.Io) void {
    _ = si;
    _ = io;
}

/// Appends the symbols for the instruction at `addr` to `symbols`.
pub fn getSymbols(
    si: *SelfInfo,
    io: std.Io,
    symbol_allocator: std.mem.Allocator,
    text_arena: std.mem.Allocator,
    addr: usize,
    include_inline_callers: bool,
    symbols: *std.ArrayList(std.debug.Symbol),
) std.debug.SelfInfoError!void {
    _ = si;
    _ = io;
    _ = text_arena;
    _ = addr;
    _ = include_inline_callers;
    try symbols.append(symbol_allocator, .unknown);
}

/// Returns a name for the "module" (e.g. shared library or executable image) containing `address`.
pub fn getModuleName(si: *SelfInfo, io: std.Io, addr: usize) std.debug.SelfInfoError![]const u8 {
    _ = si;
    _ = io;
    _ = addr;
    return "???";
}

pub fn getModuleSlide(si: *SelfInfo, io: std.Io, addr: usize) std.debug.SelfInfoError!usize {
    _ = si;
    _ = io;
    _ = addr;
    return 0;
}

/// Whether a reliable stack unwinding strategy, such as DWARF unwinding, is available.
pub const can_unwind: bool = false;
