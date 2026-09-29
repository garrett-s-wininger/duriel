const alloc = @import("allocation.zig");
const guest = @import("../guest.zig");
const linux = @import("../linux.zig");
const uart = @import("../peripherals/uart.zig");

// TODO(garrett): Determine by parsing the device tree blob rather than blindly assuming
// we're at the QEMU UART MMIO address.
const uart_base = 0x0900_0000;

pub const ConsoleUart = uart.Pl011(uart.MemoryMapped(u32));
pub const console_uart_base = uart_base;

pub const Error = error{
    InvalidGuestBootData,
    MemoryRequestFailed,
    NestedPagingNotSupported,
    NotImplemented,
    VirtualizationDisabled,
    VirtualizationNotSupported,
};

pub const GuestLaunchState = struct {};
pub const GuestPreparation = guest.Preparation(GuestLaunchState);

pub const Backend = struct {
    const Self = @This();

    pub fn isNestedPagingSupported(_: Self) bool {
        return false;
    }

    pub fn prepareVirtualization(_: *Self, _: alloc.PageAllocator, _: GuestPreparation) Error!void {
        return error.NotImplemented;
    }

    pub fn runGuest(_: Self) guest.Exit {
        return .halt;
    }
};

pub const FaultInfo = struct {};
pub const FatalFaultHandler = *const fn (FaultInfo) noreturn;

pub fn detect() Error!Backend {
    return error.NotImplemented;
}

pub fn initializeHostAddressSpace(_: alloc.PageAllocator) Error!void {}

pub fn initializeHostExecutionContext() Error!void {
    return error.NotImplemented;
}

pub fn initializeInterrupts(_: FatalFaultHandler) void {}

pub fn nameForInterruptVector(_: u8) []const u8 {
    return "Unknown";
}

pub fn prepareGuest(_: alloc.PageAllocator, _: guest.BootData) Error!GuestPreparation {
    return error.NotImplemented;
}

pub fn hlt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}
