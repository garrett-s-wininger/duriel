const hypervisor = @import("hypervisor.zig");
const std = @import("std");
const uefi = std.os.uefi;

pub export fn efiMain(
    _: uefi.Handle,
    _: *uefi.tables.SystemTable,
) callconv(.c) usize {
    var serial = hypervisor.Serial{
        .access = .{
            .base = hypervisor.console_uart_base,
        },
    };

    serial.init(null);
    const logger = hypervisor.Logger{ .sink = &serial };

    logger.log("\r\n");
    logger.log("Hello from RISC-V!");

    while (true) {
        asm volatile ("wfi");
    }

    return 1;
}
