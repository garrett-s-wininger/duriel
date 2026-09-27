pub const page_size = 4096;

pub const PageAllocator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Error = error{AllocationFailed};

    pub const VTable = struct { allocatePages: *const fn (*anyopaque, usize) Error!u64 };

    pub fn allocatePages(self: @This(), count: usize) Error!u64 {
        return self.vtable.allocatePages(self.ptr, count);
    }
};
