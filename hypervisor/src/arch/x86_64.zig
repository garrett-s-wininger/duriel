const amd = @import("x86_64/amd.zig");
const alloc = @import("allocation.zig");
const cpuid = @import("x86_64/cpuid.zig");
const gdt = @import("x86_64/gdt.zig");
const guest = @import("../guest.zig");
const guest_state = @import("x86_64/guest_state.zig");
const idt = @import("x86_64/idt.zig");
const inst = @import("x86_64/inst.zig");
const linux = @import("../linux.zig");
const multitasking = @import("x86_64/multitasking.zig");
const uart = @import("../peripherals/uart.zig");
const paging = @import("x86_64/paging.zig");
const raw = @import("x86_64/raw_boot.zig");
const std = @import("std");
const x64_linux = @import("x86_64/linux_boot.zig");
const x64_uart = @import("x86_64/uart.zig");

pub const ConsoleUart = uart.Ns16550(x64_uart.PortMapped);

// TODO(garrett): Don't hardcode COM1, automatically detect and select a console UART.
pub const console_uart_base = x64_uart.com1;

pub const Error = error{
    InvalidGuestBootData,
    MemoryRequestFailed,
    NestedPagingNotSupported,
    NotImplemented,
    UnknownVendor,
    VirtualizationDisabled,
    VirtualizationNotSupported,
};

pub const FaultInfo = idt.FaultInfo;
pub const GuestLaunchState = guest_state.LaunchState;
pub const GuestPreparation = guest.Preparation(GuestLaunchState);

pub const Backend = union(enum) {
    // TODO(garrett): Add Intel variant
    amd: amd.Backend,

    const Self = @This();

    pub fn prepareVirtualization(self: *Self, allocator: alloc.PageAllocator, prepared_guest: GuestPreparation) Error!void {
        return switch (self.*) {
            .amd => |*backend| {
                if (!backend.isVirtualizationSupported()) return error.VirtualizationNotSupported;
                if (backend.isVirtualizationDisabled()) return error.VirtualizationDisabled;
                if (!backend.isNestedPagingSupported()) return error.NestedPagingNotSupported;

                // TODO(garrett): Move from our hardcoded host save area and vm control
                // (+ 4-level extended/nested page table) to a more dynamic setup.
                const allocation_start_address = allocator.allocatePages(6) catch {
                    return error.MemoryRequestFailed;
                };

                backend.prepareVirtualization(allocation_start_address, prepared_guest.instance, prepared_guest.launch_state);
            },
        };
    }

    pub fn maxExtendedFunc(self: Self) u32 {
        return switch (self) {
            .amd => |backend| backend.max_extended_func,
        };
    }

    pub fn maxStandardFunc(self: Self) u32 {
        return switch (self) {
            .amd => |backend| backend.max_standard_func,
        };
    }

    pub fn runGuest(self: Self) guest.Exit {
        return switch (self) {
            .amd => |backend| {
                const exit = backend.runGuest();

                switch (exit.code) {
                    0x78 => return .halt,
                    0x400 => return .{
                        .second_stage_fault = .{
                            .guest_physical_address = exit.info2,
                            .raw_status = exit.info1,
                        },
                    },
                    else => |code| return .{ .unexpected = code },
                }
            },
        };
    }

    pub fn vendorString(self: @This()) []const u8 {
        return switch (self) {
            .amd => amd.vendor_string,
        };
    }
};

pub fn detect() Error!Backend {
    const basic_info = cpuid.max_standard_func_and_vendor();

    if (std.mem.eql(u8, basic_info.vendor[0..12], amd.vendor_string)) {
        return .{
            .amd = .{
                .max_extended_func = cpuid.max_extended_func(),
                .max_standard_func = basic_info.max_standard_func,
                .vmcb = null,
            },
        };
    } else {
        return error.UnknownVendor;
    }
}

// TODO(garrett): We blindly assume a 1GiB range is appropriate for our use case in this setup.
// Additional work is needed for a more robust virtual memory mapping implementation.
pub fn initializeHostAddressSpace(allocator: alloc.PageAllocator) Error!void {
    // NOTE(garrett): x86_64 defines each level of the memory mapping to be a page each. Since
    // we're using 2MiB large pages, the PTE level is not required so we only have 3 pages
    // encompassing the PML4, PDPT, and PDT levels that are required.
    const page_table_start = allocator.allocatePages(3) catch {
        return error.MemoryRequestFailed;
    };

    const page_directory_pointer_start = page_table_start + alloc.page_size;
    const page_directory_table_start = page_table_start + (2 * alloc.page_size);

    const page_tables: []align(alloc.page_size) u8 = @as(
        [*]align(alloc.page_size) u8,
        @ptrFromInt(page_table_start),
    )[0 .. alloc.page_size * 3];

    @memset(page_tables, 0);

    const pdt: *paging.PageDirectoryTable = @ptrFromInt(page_directory_table_start);
    const two_mib = 2 * 1024 * 1024;

    for (pdt, 0..) |*entry, idx| {
        entry.page_table_address = @truncate((two_mib * idx) >> 12);
        entry._low = paging.present | paging.read_write | paging.large_page;
    }

    const pdpt: *paging.PageDirectoryPointerTable = @ptrFromInt(page_directory_pointer_start);
    pdpt[0].page_directory_address = @truncate(page_directory_table_start >> 12);
    pdpt[0]._low = paging.present | paging.read_write;

    const pml4: *paging.PageMapLevel4Table = @ptrFromInt(page_table_start);
    pml4[0].page_directory_pointer_address = @truncate(page_directory_pointer_start >> 12);
    pml4[0]._low = paging.present | paging.read_write;

    inst.writeCr3(page_table_start);
}

var tss = multitasking.TaskStateSegment{
    .reserved1 = 0,
    .rsp0 = 0,
    .rsp1 = 0,
    .rsp2 = 0,
    .reserved2 = 0,
    .ist1 = 0,
    .ist2 = 0,
    .ist3 = 0,
    .ist4 = 0,
    .ist5 = 0,
    .ist6 = 0,
    .ist7 = 0,
    .reserved3 = 0,
    .reserved4 = 0,
    .io_bitmap_offset = multitasking.tss_size,
};

// NOTE(garrett): This should be initialized once and then treated as a constant for the
// lifetime of the Hypervisor.
var descriptor_table: inst.DescriptorTableRegister = undefined;
var gdt_entries: [5]gdt.Entry = .{
    gdt.Entry{
        .segment_descriptor = gdt.SegmentDescriptor.nullEntry(),
    },
    gdt.Entry{
        .segment_descriptor = gdt.SegmentDescriptor{
            .limit_low = 0,
            .base_low = 0,
            .base_middle = 0,
            .access = gdt.AccessFlags{
                .type = gdt.AccessType{
                    .code = gdt.CodeAccess{
                        .accessed = 0,
                        .readable = 1,
                        .conforming = 0,
                        .must_be_1 = 1,
                    },
                },
                .is_code_or_data = 1,
                .descriptor_privilege_level = 0,
                .present = 1,
            },
            .limit_high = 0,
            .flags = gdt.Flags{
                .available = 0,
                .is_long_mode = 1,
                .is_32_bit = 0,
                .is_limit_in_page_granularity = 0,
            },
            .base_high = 0,
        },
    },
    gdt.Entry{
        .segment_descriptor = gdt.SegmentDescriptor{
            .limit_low = 0,
            .base_low = 0,
            .base_middle = 0,
            .access = gdt.AccessFlags{
                .type = gdt.AccessType{
                    .data = gdt.DataAccess{
                        .accessed = 0,
                        .writable = 1,
                        .expand_down = 0,
                        .must_be_0 = 0,
                    },
                },
                .is_code_or_data = 1,
                .descriptor_privilege_level = 0,
                .present = 1,
            },
            .limit_high = 0,
            .flags = gdt.Flags{
                .available = 0,
                .is_long_mode = 0,
                .is_32_bit = 0,
                .is_limit_in_page_granularity = 0,
            },
            .base_high = 0,
        },
    },
    gdt.Entry{
        .segment_descriptor = gdt.SegmentDescriptor{
            .limit_low = 0,
            .base_low = 0,
            .base_middle = 0,
            .access = gdt.AccessFlags{
                .type = gdt.AccessType{
                    .system = gdt.SystemAccess.tss_available,
                },
                .is_code_or_data = 0,
                .descriptor_privilege_level = 0,
                .present = 1,
            },
            .limit_high = 0,
            .flags = gdt.Flags{
                .available = 0,
                .is_long_mode = 0,
                .is_32_bit = 0,
                .is_limit_in_page_granularity = 0,
            },
            .base_high = 0,
        },
    },
    gdt.Entry{
        .system_segment_expansion = gdt.SystemSegmentExpansion{
            .base_address_uppermost = 0,
            .reserved1 = 0,
            .must_be_0 = 0,
            .reserved2 = 0,
        },
    },
};

const code_segment_selector = gdt.SegmentSelector{
    .privilege_level = 0,
    .table_selector = 0,
    .table_index = 1,
};

const data_segment_selector = gdt.SegmentSelector{
    .privilege_level = 0,
    .table_selector = 0,
    .table_index = 2,
};

const task_segment_selector = gdt.SegmentSelector{
    .privilege_level = 0,
    .table_selector = 0,
    .table_index = 3,
};

pub fn initializeHostExecutionContext() Error!void {
    descriptor_table = inst.DescriptorTableRegister{
        .limit = (@sizeOf(gdt.SegmentDescriptor) * gdt_entries.len) - 1,
        .base = @intFromPtr(&gdt_entries[0]),
    };

    const tss_limit: usize = multitasking.tss_size - 1;
    const tss_address: u64 = @intFromPtr(&tss);
    const tss_entry: usize = 3;

    gdt_entries[tss_entry].segment_descriptor.limit_low = @truncate(tss_limit);
    gdt_entries[tss_entry].segment_descriptor.limit_high = @truncate(tss_limit >> 16);
    gdt_entries[tss_entry].segment_descriptor.base_low = @truncate(tss_address);
    gdt_entries[tss_entry].segment_descriptor.base_middle = @truncate(tss_address >> 16);
    gdt_entries[tss_entry].segment_descriptor.base_high = @truncate(tss_address >> 24);
    gdt_entries[tss_entry + 1].system_segment_expansion.base_address_uppermost = @truncate(tss_address >> 32);
    inst.loadGlobalDescriptorTable(&descriptor_table);

    const segment_selector: u16 = @bitCast(code_segment_selector);
    inst.reloadCodeSegment(segment_selector);
    inst.setDataSegments(@bitCast(data_segment_selector));
    inst.loadTaskRegister(@bitCast(task_segment_selector));
}

pub fn initializeInterrupts(handler: idt.FatalFaultHandler) void {
    idt.fatal_fault_handler = handler;

    const code_segment: u16 = @bitCast(code_segment_selector);

    for (0..idt.interrupt_table.len) |idx| {
        idt.interrupt_table[idx] = idt.gateForAddress(
            code_segment,
            @intFromPtr(&idt.defaultHandler),
        );
    }

    idt.interrupt_table[idt.invalid_opcode_vector] = idt.gateForAddress(
        code_segment,
        @intFromPtr(&idt.invalidOpcodeEntry),
    );

    idt.interrupt_table[idt.general_protection_vector] = idt.gateForAddress(
        code_segment,
        @intFromPtr(&idt.generalProtectionFaultEntry),
    );

    idt.interrupt_table[idt.page_fault_vector] = idt.gateForAddress(
        code_segment,
        @intFromPtr(&idt.pageFaultEntry),
    );

    var interrupt_descriptor_register = inst.DescriptorTableRegister{
        .limit = @sizeOf(idt.InterruptDescriptorTable) - 1,
        .base = @intFromPtr(&idt.interrupt_table),
    };

    inst.loadInterruptDescriptorTable(&interrupt_descriptor_register);
}

pub fn prepareGuest(allocator: alloc.PageAllocator, boot_data: guest.BootData) Error!GuestPreparation {
    return switch (boot_data) {
        .raw => |raw_boot| prepareRawGuest(allocator, raw_boot),
        .linux => |linux_boot| prepareLinuxGuest(allocator, linux_boot),
    };
}

fn prepareRawGuest(allocator: alloc.PageAllocator, raw_boot: guest.RawBootData) Error!GuestPreparation {
    // TODO(garrett): Support larger binary files.
    if (raw_boot.bytes.len > alloc.page_size) {
        return error.InvalidGuestBootData;
    }

    // NOTE(garrett): We register our guest with 1 code page, 1 stack page, and the
    // 4-level page tables as the remainder for simplicity.
    const memory = guest.Memory.init(allocator, 6) catch {
        return error.MemoryRequestFailed;
    };

    const payload: [*]u8 = @ptrFromInt(memory.host_physical_start);
    @memcpy(payload[0..raw_boot.bytes.len], raw_boot.bytes);

    return .{
        .instance = .{ .memory = memory },
        .launch_state = raw.launchState(memory),
    };
}

fn prepareLinuxGuest(_: alloc.PageAllocator, boot_data: linux.KernelBootData) Error!GuestPreparation {
    const kernel = boot_data.kernel() catch return error.InvalidGuestBootData;
    const boot_configuration = x64_linux.parseHeader(kernel) catch return error.InvalidGuestBootData;

    const kernel_range_start = x64_linux.high_memory_load_address;
    const kernel_range_end = std.math.add(
        usize,
        kernel_range_start,
        boot_configuration.header.initialization_size,
    ) catch return error.InvalidGuestBootData;

    const initramfs = boot_data.initramfs() catch return error.InvalidGuestBootData;
    if (initramfs.len == 0) return error.InvalidGuestBootData;

    const initramfs_start = std.mem.alignForward(usize, kernel_range_end, alloc.page_size);
    const initramfs_end = std.math.add(
        usize,
        initramfs_start,
        initramfs.len,
    ) catch return error.InvalidGuestBootData;

    if (initramfs_end - 1 > boot_configuration.header.initrd_max_address) return error.InvalidGuestBootData;

    // TODO(garrett): Continue to flesh out
    return error.NotImplemented;
}

pub fn hlt() noreturn {
    while (true) {
        asm volatile (
            \\cli
            \\hlt
        );
    }
}

pub fn nameForInterruptVector(interrupt_vector: u8) []const u8 {
    switch (interrupt_vector) {
        idt.invalid_opcode_vector => return "Invalid Opcode",
        idt.general_protection_vector => return "General Protection Fault",
        idt.page_fault_vector => return "Page Fault",
        else => return "Unknown Fault",
    }
}
