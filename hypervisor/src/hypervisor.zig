const alloc = @import("arch/allocation.zig");
const builtin = @import("builtin");
const guest = @import("guest.zig");
const logging = @import("logging.zig");
const linux = @import("linux.zig");
const std = @import("std");
const uefi = std.os.uefi;

pub const Serial = Architecture.ConsoleUart;
pub const Logger = logging.Logger(Serial);

const Architecture = switch (builtin.cpu.arch) {
    .aarch64 => @import("arch/aarch64.zig"),
    .x86_64 => @import("arch/x86_64.zig"),
    .riscv64 => @import("arch/riscv64.zig"),
    else => |architecture| @compileError("Unsupported architecture: " ++ @tagName(architecture)),
};

pub const console_uart_base = Architecture.console_uart_base;

pub const UefiHandoff = struct {
    memory_map: uefi.tables.MemoryMapSlice,
    boot_data: guest.BootData,
};

// NOTE(garrett): This allocator is intentionally a minimal, post-UEFI example. We only select
// the single largest range of conventional memory from our map and never free.
const BootstrapAllocator = struct {
    region: []align(alloc.page_size) u8,
    offset: usize,

    const vtable = alloc.PageAllocator.VTable{ .allocatePages = &allocatePages };

    const Error = error{NoValidMemoryRange};

    pub fn allocatePages(ctx: *anyopaque, count: usize) alloc.PageAllocator.Error!u64 {
        const allocator: *@This() = @ptrCast(@alignCast(ctx));

        // TODO(garrett): Update to overflow-safe math in the presence of dynamic page
        // allocation counts.
        const new_offset = (alloc.page_size * count) + allocator.offset;
        if (new_offset > allocator.region.len) {
            return error.AllocationFailed;
        }

        const old_offset = allocator.offset;
        allocator.offset = new_offset;

        return @intFromPtr(allocator.region.ptr) + old_offset;
    }

    pub fn asPageAllocator(self: *@This()) alloc.PageAllocator {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn init(memory_map: uefi.tables.MemoryMapSlice) Error!@This() {
        var selected: ?*uefi.tables.MemoryDescriptor = null;
        var iterator = memory_map.iterator();

        while (iterator.next()) |descriptor| {
            if (descriptor.type != .conventional_memory) continue;
            if (selected != null and descriptor.number_of_pages <= selected.?.number_of_pages) continue;

            kernel_logger.logFormatted(
                "Memory Selection: 0x{x} for {d} pages",
                .{ descriptor.physical_start, descriptor.number_of_pages },
            );

            selected = descriptor;
        }

        const descriptor = selected orelse return error.NoValidMemoryRange;

        // TODO(garrett): We assume we still have the identity-mapped pages inherited from the UEFI firmware. When
        // we have our own page tables, this assumption no longer holds and we'll have to adjust the addressing.
        return .{
            .region = @as(
                [*]align(alloc.page_size) u8,
                @ptrFromInt(descriptor.physical_start),
            )[0..(descriptor.number_of_pages * alloc.page_size)],
            .offset = 0,
        };
    }
};

var kernel_logger: Logger = undefined;

fn x86_64_panic(fault_info: Architecture.FaultInfo) void {
    kernel_logger.logFormatted("\r\nKernel Panic from {s} (Error Code:  0x{X:0>16}):\r\n", .{
        Architecture.nameForInterruptVector(fault_info.interrupt_vector),
        fault_info.error_code,
    });

    if (fault_info.fault_address) |address| {
        kernel_logger.logFormatted("  CR2:    0x{X:0>16}", .{address});
    }

    kernel_logger.logFormatted("  RIP:    0x{X:0>16}", .{fault_info.instruction_pointer});
    kernel_logger.logFormatted("  RSP:    0x{X:0>16}", .{fault_info.stack_pointer});
    kernel_logger.logFormatted("  RFLAGS: 0x{X:0>16}", .{fault_info.register_flags});
}

fn panic(fault_info: Architecture.FaultInfo) noreturn {
    if (builtin.target.cpu.arch == .x86_64) x86_64_panic(fault_info);
    Architecture.hlt();
}

pub fn enter(logger: Logger, handoff_data: UefiHandoff) noreturn {
    kernel_logger = logger;

    var cpu = Architecture.detect() catch {
        kernel_logger.log("Unsupported processor vendor detected.");
        Architecture.hlt();
    };

    var bootstrap_allocator = BootstrapAllocator.init(handoff_data.memory_map) catch {
        kernel_logger.log("No valid memory range could be found for initialization.");
        Architecture.hlt();
    };

    const allocator = bootstrap_allocator.asPageAllocator();
    Architecture.initializeHostAddressSpace(allocator) catch {
        kernel_logger.log("Failed to initialize host address space.");
        Architecture.hlt();
    };

    kernel_logger.log("Host page tables installed.");
    Architecture.initializeHostExecutionContext() catch {
        kernel_logger.log("Failed to configure host execution context.");
        Architecture.hlt();
    };

    kernel_logger.log("Host execution context configured.");
    Architecture.initializeInterrupts(&panic);
    kernel_logger.log("Interrupt handlers installed.");

    // TODO(garrett): Create halting guests for AArch64 + RISC-V 64.
    if (builtin.cpu.arch != .x86_64) {
        kernel_logger.log("Current CPU architecture does not have a guest to run");
        Architecture.hlt();
    }

    // TODO(garrett): Move to Linux guest preparation.
    const prepared_guest = Architecture.prepareGuest(allocator, .{ .raw = .{ .bytes = &.{0xF4} } }) catch |err| switch (err) {
        error.InvalidGuestBootData => {
            kernel_logger.log("Boot data determined to be invalid.");
            Architecture.hlt();
        },
        error.MemoryRequestFailed => {
            kernel_logger.log("Failed to obtain sufficient memory to launch guest.");
            Architecture.hlt();
        },
        error.NotImplemented => {
            kernel_logger.log("Reached unimplemented guest execution code.");
            Architecture.hlt();
        },
        else => {
            kernel_logger.log("Failed to prepare guest.");
            Architecture.hlt();
        },
    };

    kernel_logger.logFormatted("Guest Memory Assignment: 0x{X:0>8}", .{prepared_guest.instance.memory.host_physical_start});

    cpu.prepareVirtualization(allocator, prepared_guest) catch |err| switch (err) {
        error.MemoryRequestFailed => {
            kernel_logger.log("Required memory could not be allocated.");
            Architecture.hlt();
        },
        error.NestedPagingNotSupported => {
            kernel_logger.log("Nested paging is not supported.");
            Architecture.hlt();
        },
        error.VirtualizationDisabled => {
            kernel_logger.log("Virtualization has been disabled, please check firmware settings.");
            Architecture.hlt();
        },
        error.VirtualizationNotSupported => {
            kernel_logger.log("Processor does not support virtualization.");
            Architecture.hlt();
        },
        else => {
            kernel_logger.log("An unknown error occurred; aborting.");
            Architecture.hlt();
        },
    };

    const status = cpu.runGuest();

    switch (status) {
        .halt => kernel_logger.log("Guest boot successful!"),
        .second_stage_fault => |fault_info| {
            kernel_logger.log("Guest encountered nested page fault:");
            kernel_logger.logFormatted(
                "  Address: 0x{X:0>16}  Status: 0x{X:0>16}",
                .{
                    fault_info.guest_physical_address,
                    fault_info.raw_status,
                },
            );
        },
        .unexpected => |exit_code| kernel_logger.logFormatted(
            "Guest exited unexpectedly with code: 0x{X:0>16}",
            .{exit_code},
        ),
    }

    kernel_logger.log("Hypervisor now halted.");
    Architecture.hlt();
}
