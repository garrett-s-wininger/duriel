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

            std.log.debug(
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

fn x86_64_panic(fault_info: Architecture.FaultInfo) void {
    std.log.err("\r\nKernel Panic from {s} (Error Code:  0x{X:0>16}):\r\n", .{
        Architecture.nameForInterruptVector(fault_info.interrupt_vector),
        fault_info.error_code,
    });

    if (fault_info.fault_address) |address| {
        std.log.err("  CR2:    0x{X:0>16}", .{address});
    }

    std.log.err("  RIP:    0x{X:0>16}", .{fault_info.instruction_pointer});
    std.log.err("  RSP:    0x{X:0>16}", .{fault_info.stack_pointer});
    std.log.err("  RFLAGS: 0x{X:0>16}", .{fault_info.register_flags});
}

fn panic(fault_info: Architecture.FaultInfo) noreturn {
    if (builtin.target.cpu.arch == .x86_64) x86_64_panic(fault_info);
    Architecture.hlt();
}

pub fn enter(handoff_data: UefiHandoff) noreturn {
    var cpu = Architecture.detect() catch {
        std.log.err("Unsupported processor vendor detected.", .{});
        Architecture.hlt();
    };

    var bootstrap_allocator = BootstrapAllocator.init(handoff_data.memory_map) catch {
        std.log.err("No valid memory range could be found for initialization.", .{});
        Architecture.hlt();
    };

    const allocator = bootstrap_allocator.asPageAllocator();
    Architecture.initializeHostAddressSpace(allocator) catch {
        std.log.err("Failed to initialize host address space.", .{});
        Architecture.hlt();
    };

    std.log.info("Host page tables installed.", .{});
    Architecture.initializeHostExecutionContext() catch {
        std.log.err("Failed to configure host execution context.", .{});
        Architecture.hlt();
    };

    std.log.info("Host execution context configured.", .{});
    Architecture.initializeInterrupts(&panic);
    std.log.info("Interrupt handlers installed.", .{});

    // TODO(garrett): Create halting guests for AArch64 + RISC-V 64.
    if (builtin.cpu.arch != .x86_64) {
        std.log.err("Current CPU architecture does not have a guest to run", .{});
        Architecture.hlt();
    }

    const prepared_guest = Architecture.prepareGuest(
        allocator,
        .{
            .boot_data = handoff_data.boot_data,
            .memory_amount_mb = 64,
        },
    ) catch |err| switch (err) {
        error.InvalidGuestBootData => {
            std.log.err("Boot data determined to be invalid.", .{});
            Architecture.hlt();
        },
        error.MemoryRequestFailed => {
            std.log.err("Failed to obtain sufficient memory to launch guest.", .{});
            Architecture.hlt();
        },
        error.NotImplemented => {
            std.log.err("Reached unimplemented guest execution code.", .{});
            Architecture.hlt();
        },
        else => {
            std.log.err("Failed to prepare guest.", .{});
            Architecture.hlt();
        },
    };

    std.log.info("Guest Memory Assignment: 0x{X:0>8}", .{prepared_guest.instance.memory.host_physical_start});

    cpu.prepareVirtualization(allocator, prepared_guest) catch |err| switch (err) {
        error.MemoryRequestFailed => {
            std.log.err("Required memory could not be allocated.", .{});
            Architecture.hlt();
        },
        error.VirtualizationDisabled => {
            std.log.err("Virtualization has been disabled, please check firmware settings.", .{});
            Architecture.hlt();
        },
        error.VirtualizationFeatureMissing => {
            std.log.err("A required virtualization feature is not present on the CPU.", .{});
            Architecture.hlt();
        },
        error.VirtualizationNotSupported => {
            std.log.err("Processor does not support virtualization.", .{});
            Architecture.hlt();
        },
        else => {
            std.log.err("An unknown error occurred; aborting.", .{});
            Architecture.hlt();
        },
    };

    const status = cpu.runGuest();

    switch (status) {
        .halt => std.log.info("Guest halted.", .{}),
        .second_stage_fault => |fault_info| {
            std.log.err("Guest encountered nested page fault:", .{});
            std.log.err(
                "  Address: 0x{X:0>16}  Status: 0x{X:0>16}",
                .{
                    fault_info.guest_physical_address,
                    fault_info.raw_status,
                },
            );
        },
        .unexpected => |exit_code| std.log.err(
            "Guest exited unexpectedly with code: 0x{X:0>16}",
            .{exit_code},
        ),
    }

    std.log.info("Hypervisor halted.", .{});
    Architecture.hlt();
}
