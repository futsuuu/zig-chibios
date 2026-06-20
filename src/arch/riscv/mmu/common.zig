const std = @import("std");

pub const Flags = packed struct {
    valid: bool = true,
    readable: bool = false,
    writable: bool = false,
    executable: bool = false,
    usermode: bool = false,
    global: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    _: u2 = 0,

    pub const ptr: Flags = .{};
    pub const r: Flags = .{ .readable = true };
    pub const rw: Flags = .{ .readable = true, .writable = true };
    pub const x: Flags = .{ .executable = true };
    pub const rx: Flags = .{ .readable = true, .executable = true };
    pub const rwx: Flags = .{ .readable = true, .writable = true, .executable = true };

    pub fn assertValid(comptime self: Flags) void {
        if (!self.valid) {
            @compileError("invalid flags");
        }
        if (self.writable and !self.readable) {
            @compileError(std.fmt.comptimePrint("reserved flags: {f}", .{self}));
        }
    }

    pub fn format(self: Flags, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte(if (0 < self._ & 0b10) '1' else '-');
        try writer.writeByte(if (0 < self._ & 0b01) '1' else '-');
        try writer.writeByte(if (self.dirty) 'd' else '-');
        try writer.writeByte(if (self.accessed) 'a' else '-');
        try writer.writeByte(if (self.global) 'g' else '-');
        try writer.writeByte(if (self.usermode) 'u' else '-');
        try writer.writeByte(if (self.executable) 'x' else '-');
        try writer.writeByte(if (self.writable) 'w' else '-');
        try writer.writeByte(if (self.readable) 'r' else '-');
        try writer.writeByte(if (self.valid) 'v' else '-');
    }
};
