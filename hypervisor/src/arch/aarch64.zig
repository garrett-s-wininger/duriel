const alloc = @import("allocation.zig");
const guest = @import("../guest.zig");
const uart = @import("../peripherals/uart.zig");

// TODO(garrett): Determine by parsing the device tree blob rather than blindly assuming
// we're at the QEMU UART MMIO address.
const uart_base = 0x0900_0000;

pub const ConsoleUart = uart.Pl011(uart.MemoryMapped(u32));
pub const console_uart_base = uart_base;

pub const Error = error{
    MemoryRequestFailed,
    NestedPagingNotSupported,
    NotImplemented,
    VirtualizationDisabled,
    VirtualizationNotSupported,
};

pub const Backend = struct {
    const Self = @This();

    pub fn isNestedPagingSupported(_: Self) bool {
        return false;
    }

    pub fn prepareVirtualization(_: *Self, _: alloc.PageAllocator, _: guest.Instance, _: GuestLaunchState) Error!void {
        return error.NotImplemented;
    }

    pub fn runGuest(_: Self) guest.Exit {
        return .halt;
    }
};

pub const FaultInfo = struct {};
pub const FatalFaultHandler = *const fn (FaultInfo) noreturn;
pub const GuestLaunchState = struct {};

pub fn detect() Error!Backend {
    return error.NotImplemented;
}

pub fn initializeHostAddressSpace(_: alloc.PageAllocator) Error!void {}

pub fn initializeHostExecutionContext() Error!void {
    return error.NotImplemented;
}

pub fn initializeGuestAddressSpace(_: guest.Memory) u64 {
    return 0;
}

pub fn initializeInterrupts(_: FatalFaultHandler) void {}

pub fn nameForInterruptVector(_: u8) []const u8 {
    return "Unknown";
}

pub fn prepareLinuxGuest(_: guest.Instance, _: u64) GuestLaunchState {
    return .{};
}

pub fn hlt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}
