const std = @import("std");

pub const Error = error{OutOfBounds};

pub const KernelBootData = struct {
    data: []const u8,
    kernel_offset: usize,
    kernel_size: usize,
    initramfs_offset: usize,
    initramfs_size: usize,

    const Self = @This();

    pub fn kernel(self: Self) Error![]const u8 {
        const kernel_start = self.kernel_offset;
        const kernel_end = std.math.add(
            usize,
            kernel_start,
            self.kernel_size,
        ) catch return error.OutOfBounds;

        if (kernel_end > self.data.len) return error.OutOfBounds;
        return self.data[kernel_start..kernel_end];
    }

    pub fn initramfs(self: Self) Error![]const u8 {
        const initramfs_start = self.initramfs_offset;
        const initramfs_end = std.math.add(
            usize,
            initramfs_start,
            self.initramfs_size,
        ) catch return error.OutOfBounds;

        if (initramfs_end > self.data.len) return error.OutOfBounds;
        return self.data[initramfs_start..initramfs_end];
    }
};
