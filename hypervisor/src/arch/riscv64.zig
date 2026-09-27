const uart = @import("../peripherals/uart.zig");

// TODO(garrett): Determine by parsing the device tree blob rather than blindly assuming
// we're at the QEMU UART MMIO address.
const uart_base = 0x1000_0000;

pub const ConsoleUart = uart.Ns16550(uart.MemoryMapped(u8));
pub const console_uart_base = uart_base;
