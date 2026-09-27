const alloc = @import("arch/allocation.zig");

pub const Memory = struct {
    host_physical_start: u64,
    page_count: usize,

    const Self = @This();

    pub fn init(allocator: alloc.PageAllocator, page_count: usize) alloc.PageAllocator.Error!Self {
        const host_start = try allocator.allocatePages(page_count);
        const memory = @as([*]align(alloc.page_size) u8, @ptrFromInt(host_start))[0 .. page_count * alloc.page_size];

        @memset(memory, 0);

        return Self{
            .host_physical_start = host_start,
            .page_count = page_count,
        };
    }
};

pub const Instance = struct {
    memory: Memory,
};

pub const SecondStageFault = struct {
    guest_physical_address: u64,
    raw_status: u64,
};

pub const Exit = union(enum) {
    halt,
    second_stage_fault: SecondStageFault,
    unexpected: u64,
};
