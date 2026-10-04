const hypervisor = @import("hypervisor.zig");
const std = @import("std");
const uefi = std.os.uefi;

pub const std_options: std.Options = .{
    .logFn = hypervisor.Logger.logFn,
};

pub const panic = std.debug.FullPanic(struct {
    fn handle(msg: []const u8, _: ?usize) noreturn {
        hypervisor.Logger.log("\r\nZig Panic:\r\n");
        hypervisor.Logger.log(msg);
        @trap();
    }
}.handle);

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
    hypervisor.Logger.install(&serial);

    std.log.info("\r\n", .{});
    std.log.info("Hello from RISC-V!", .{});

    while (true) {
        asm volatile ("wfi");
    }

    return 1;
}
