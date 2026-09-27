pub fn MemoryMapped(comptime RegisterWidth: type) type {
    return struct {
        base: usize,

        const Self = @This();

        pub fn read(self: *const Self, offset: usize) RegisterWidth {
            const register: *volatile RegisterWidth = @ptrFromInt(self.base + offset);
            return register.*;
        }

        pub fn write(self: *const Self, offset: usize, value: RegisterWidth) void {
            const register: *volatile RegisterWidth = @ptrFromInt(self.base + offset);
            register.* = value;
        }
    };
}
