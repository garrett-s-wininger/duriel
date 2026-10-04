const alloc = @import("arch/allocation.zig");
const hypervisor = @import("hypervisor.zig");
const linux = @import("linux.zig");
const std = @import("std");
const uefi = std.os.uefi;

// NOTE(garrett): These pieces are a bit of magic so our global logging facilities can run
// through the Zig std.log.* set of functions as well as allow us to use the @panic
// built-ins for debugging.
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

fn readFileSize(source: *uefi.protocol.File) usize {
    source.setPosition(std.math.maxInt(u64)) catch unreachable;
    const source_size = source.getPosition() catch unreachable;
    source.setPosition(0) catch unreachable;

    return source_size;
}

fn readFileContentsToBuffer(destination: []u8, source: *uefi.protocol.File, source_size: usize) uefi.Error!void {
    std.debug.assert(destination.len >= source_size);
    var offset: usize = 0;
    var left_to_read = source_size;

    while (left_to_read > 0) {
        const amount_read = source.read(destination[offset..]) catch {
            return error.Unexpected;
        };

        if (amount_read == 0) return error.Unexpected;

        offset += amount_read;
        left_to_read -= amount_read;
    }
}

fn loadDomainData(
    boot_services: *uefi.tables.BootServices,
) uefi.Error!linux.KernelBootData {
    std.log.info("Loading files from the ESP...", .{});

    const loaded_image = (try boot_services.handleProtocol(
        uefi.protocol.LoadedImage,
        uefi.handle,
    )) orelse return error.Unsupported;

    const device_handle = loaded_image.device_handle orelse return error.Unsupported;

    const file_system = (try boot_services.handleProtocol(
        uefi.protocol.SimpleFileSystem,
        device_handle,
    )) orelse return error.Unsupported;

    // TODO(garrett): Move these out of the ESP.
    const volume = file_system.openVolume() catch return error.Unexpected;
    const kernel_path = std.unicode.utf8ToUtf16LeStringLiteral("\\domains\\placeholder\\kernel.bzImage");
    const initramfs_path = std.unicode.utf8ToUtf16LeStringLiteral("\\domains\\placeholder\\initramfs.cpio");

    const kernel_file = volume.open(kernel_path, .read, @bitCast(@as(u64, 0))) catch return error.Unexpected;
    const initramfs_file = volume.open(initramfs_path, .read, @bitCast(@as(u64, 0))) catch return error.Unexpected;

    defer {
        kernel_file.close() catch unreachable;
        initramfs_file.close() catch unreachable;
        volume.close() catch unreachable;
    }

    const kernel_file_size = readFileSize(kernel_file);
    const initramfs_file_size = readFileSize(initramfs_file);
    const required_pages = std.math.divCeil(usize, kernel_file_size + initramfs_file_size, alloc.page_size) catch unreachable;
    const boot_data_allocation = boot_services.allocatePages(.any, .loader_data, required_pages) catch {
        std.log.err("Allocation of domain boot data failed.", .{});
        return error.Unexpected;
    };

    const boot_data_buffer: []u8 = @as([*]u8, @ptrCast(boot_data_allocation))[0 .. required_pages * alloc.page_size];
    @memset(boot_data_buffer, 0);

    readFileContentsToBuffer(boot_data_buffer, kernel_file, kernel_file_size) catch {
        std.log.err("Kernel image could not be loaded from the ESP.", .{});
        return error.Unexpected;
    };

    readFileContentsToBuffer(boot_data_buffer[kernel_file_size..], initramfs_file, initramfs_file_size) catch {
        std.log.err("InitramFS could not be loaded from the ESP.", .{});
        return error.Unexpected;
    };

    return .{
        .data = boot_data_buffer,
        .kernel_offset = 0,
        .kernel_size = kernel_file_size,
        .initramfs_offset = kernel_file_size,
        .initramfs_size = initramfs_file_size,
    };
}

fn prepareForHandoffToHypervisor(
    boot_services: *uefi.tables.BootServices,
) uefi.Error!hypervisor.UefiHandoff {
    const domain_data = loadDomainData(boot_services) catch |err| switch (err) {
        error.Unsupported => {
            std.log.err("Loading data from the ESP is unsupported.", .{});
            return err;
        },
        else => {
            return err;
        },
    };

    std.log.info("Kernel Image Size: {d} bytes", .{domain_data.kernel_size});
    std.log.info("InitramFS Size: {d} bytes", .{domain_data.initramfs_size});

    const memory_map_info = try boot_services.getMemoryMapInfo();

    if (memory_map_info.descriptor_version != 1) {
        return error.Unsupported;
    }

    const slack_descriptors = 8;
    const required_bytes = memory_map_info.descriptor_size * (slack_descriptors + memory_map_info.len);
    const required_pages = std.math.divCeil(usize, required_bytes, 4096) catch {
        std.log.err("Required page map size could not be calculated.", .{});
        return error.Unexpected;
    };

    const allocation = boot_services.allocatePages(.any, .loader_data, required_pages) catch |err| {
        std.log.err("Allocation of memory map buffer failed.", .{});
        return err;
    };

    const allocation_buffer = std.mem.sliceAsBytes(allocation);
    const memory_map = boot_services.getMemoryMap(allocation_buffer) catch |err| switch (err) {
        error.BufferTooSmall => {
            // TODO(garrett): This can be corrected by re-adjusting our allocation and
            // trying again a finite number of times. We're skipping here for simplicity.
            std.log.err("Memory map buffer was too small.", .{});
            return err;
        },
        error.InvalidParameter => {
            std.log.err("An invalid parameter was passed during memory map retrieval.", .{});
            return err;
        },
        else => {
            std.log.err("An unexpected error occurred while retrieving the memory map.", .{});
            return error.Unexpected;
        },
    };

    return .{
        .memory_map = memory_map,
        .boot_data = .{ .linux = domain_data },
    };
}

pub fn main() uefi.Error!void {
    var serial = hypervisor.Serial{
        .access = .{
            .base = hypervisor.console_uart_base,
        },
    };

    serial.init(1);
    hypervisor.Logger.install(&serial);

    const boot_services = uefi.system_table.boot_services orelse {
        std.log.err("UEFI boot services could not be detected.", .{});
        return error.Unsupported;
    };

    const handoff_data = try prepareForHandoffToHypervisor(boot_services);

    // TODO(garrett): On an invalid map key, reacquire the memory map and retry with
    // the new key. Combining this and the BufferTooSmall adjustment will result in
    // a more robust UEFI handling path.
    boot_services.exitBootServices(uefi.handle, handoff_data.memory_map.info.key) catch |err| switch (err) {
        error.InvalidParameter => {
            std.log.err("Invalid parameter on boot service exit; memory map key is likely invalid.", .{});
            return err;
        },
        else => {
            std.log.err("Failed to exit boot services for an unknown reason", .{});
            return err;
        },
    };

    std.log.info("UEFI boot service handling complete, transferring control to hypervisor...", .{});
    hypervisor.enter(handoff_data);
}
