const inst = @import("inst.zig");

pub const com1: u16 = 0x3F8;

pub const PortMapped = struct {
    base: u16,

    const Self = @This();

    pub fn read(self: *const Self, offset: usize) u8 {
        return inst.inb(self.base + @as(u16, @truncate(offset)));
    }

    pub fn write(self: *const Self, offset: usize, value: u8) void {
        inst.outb(self.base + @as(u16, @truncate(offset)), value);
    }
};
