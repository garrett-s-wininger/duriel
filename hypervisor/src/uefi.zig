const hypervisor = @import("hypervisor.zig");
const std = @import("std");
const uefi = std.os.uefi;

fn prepareForHandoffToHypervisor(
    logger: hypervisor.Logger,
    boot_services: *uefi.tables.BootServices,
) uefi.Error!hypervisor.UefiHandoff {
    const memory_map_info = try boot_services.getMemoryMapInfo();

    if (memory_map_info.descriptor_version != 1) {
        return error.Unsupported;
    }

    const slack_descriptors = 8;
    const required_bytes = memory_map_info.descriptor_size * (slack_descriptors + memory_map_info.len);
    const required_pages = std.math.divCeil(usize, required_bytes, 4096) catch {
        logger.log("Required page map size could not be calculated.");
        return error.Unexpected;
    };

    const allocation = boot_services.allocatePages(.any, .loader_data, required_pages) catch |err| {
        logger.log("Allocation of memory map buffer failed.");
        return err;
    };

    const allocation_buffer = std.mem.sliceAsBytes(allocation);
    const memory_map = boot_services.getMemoryMap(allocation_buffer) catch |err| switch (err) {
        error.BufferTooSmall => {
            // TODO(garrett): This can be corrected by re-adjusting our allocation and
            // trying again a finite number of times. We're skipping here for simplicity.
            logger.log("Memory map buffer was too small.");
            return err;
        },
        error.InvalidParameter => {
            logger.log("An invalid parameter was passed during memory map retrieval.");
            return err;
        },
        else => {
            logger.log("An unexpected error occurred while retrieving the memory map.");
            return error.Unexpected;
        },
    };

    return .{ .memory_map = memory_map, .memory_map_buffer = allocation_buffer };
}

pub fn main() uefi.Error!void {
    var serial = hypervisor.Serial{
        .access = .{
            .base = hypervisor.console_uart_base,
        },
    };

    serial.init(1);
    var logger = hypervisor.Logger{ .sink = &serial };

    const boot_services = uefi.system_table.boot_services orelse {
        logger.log("UEFI boot services could not be detected.");
        return error.Unsupported;
    };

    const handoff_data = try prepareForHandoffToHypervisor(logger, boot_services);

    // TODO(garrett): On an invalid map key, reacquire the memory map and retry with
    // the new key. Combining this and the BufferTooSmall adjustment will result in
    // a more robust UEFI handling path.
    boot_services.exitBootServices(uefi.handle, handoff_data.memory_map.info.key) catch |err| switch (err) {
        error.InvalidParameter => {
            logger.log("Invalid parameter on boot service exit; memory map key is likely invalid.");
            return err;
        },
        else => {
            logger.log("Failed to exit boot services for an unknown reason");
            return err;
        },
    };

    logger.log("UEFI boot service handling complete, transferring control to hypervisor...");
    hypervisor.enter(logger, handoff_data);
}
