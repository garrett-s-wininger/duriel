const alloc = @import("arch/allocation.zig");
const linux = @import("linux.zig");

pub const RawBootData = struct {
    bytes: []const u8,
};

pub const BootData = union(enum) {
    raw: RawBootData,
    linux: linux.KernelBootData,
};

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

pub fn Preparation(comptime LaunchState: type) type {
    return struct {
        instance: Instance,
        launch_state: LaunchState,
    };
}

pub const Specification = struct {
    // TODO(garrett): CPU placement, hardware requisition, etc.
    boot_data: BootData,
    memory_amount_mb: usize,
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
