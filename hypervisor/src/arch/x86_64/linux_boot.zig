const alloc = @import("../allocation.zig");
const gdt = @import("gdt.zig");
const guest = @import("../../guest.zig");
const guest_state = @import("guest_state.zig");
const linux = @import("../../linux.zig");
const paging = @import("paging.zig");
const std = @import("std");

pub const kernel_header_offset = 0x1f1;
pub const high_memory_load_address = 0x1000000;

const e820_count_zero_page_offset = 0x1E8;
const e820_array_zero_page_offset = 0x2D0;
const e820_max_entries = 128;
const x64_entrypoint_offset = 0x200;

pub const KernelHeader = packed struct(u984) {
    setup_sector_count: u8,
    root_flags: u16,
    code_size_32bit: u32,
    ram_size: u16,
    video_mode: u16,
    root_device: u16,
    boot_flag: u16,
    jump: u16,
    magic: u32,
    boot_version: u16,
    real_mode_switch: u32,
    system_segment_start: u16,
    kernel_version: u16,
    bootloader_identifier: u8,
    boot_protocol_flags: u8,
    setup_move_size: u16,
    code_start_32bit: u32,
    ramdisk_load_address: u32,
    ramdisk_size: u32,
    bootsector_kludge: u32,
    heap_end_pointer: u16,
    extended_loader_version: u8,
    extended_loader_type: u8,
    command_line_pointer: u32,
    initrd_max_address: u32,
    kernel_alignment: u32,
    is_kernel_relocatable: u8,
    minimum_alignment: u8,
    extended_boot_protocol_flags: u16,
    command_line_size: u32,
    hardware_subarchitecture: u32,
    hardware_subarchitecture_data: u64,
    kernel_payload_offset: u32,
    kernel_payload_length: u32,
    setup_data_pointer: u64,
    preferred_loading_address: u64,
    initialization_size: u32,
    handover_offset: u32,
    kernel_info_offset: u32,
};

comptime {
    const header_bit_size = @bitSizeOf(KernelHeader);
    if (header_bit_size != 984) @compileError("Linux kernel header must be 123 bytes (984 bits) in size.");
}

pub const BootableKernel = struct {
    header: KernelHeader,
    image: []const u8,
};

const E820RegionType = enum(u32) {
    usable = 1,
    reserved = 2,
};

const E820Entry = extern struct {
    base_address: u64 align(1),
    size: u64 align(1),
    type: u32 align(1),
};

comptime {
    if (@sizeOf(E820Entry) != 20) {
        @compileError("E820 memory map entries must be 20 bytes in size.");
    }
}

pub fn parseHeader(kernel: []const u8) linux.Error!BootableKernel {
    const kernel_header_end = kernel_header_offset + @sizeOf(KernelHeader);
    if (kernel.len < kernel_header_end) return error.OutOfBounds;

    const header_pointer: *align(1) const KernelHeader = @ptrCast(kernel[kernel_header_offset..kernel_header_end].ptr);

    const is_boot_flag_valid = header_pointer.*.boot_flag == 0xAA55;
    if (!is_boot_flag_valid) return error.InvalidHeader;

    // NOTE(garrett): The magic is defined as the string "HdrS"
    const is_magic_valid = header_pointer.*.magic == 0x53726448;
    if (!is_magic_valid) return error.InvalidHeader;

    const boot_version = header_pointer.*.boot_version;
    const boot_version_major = boot_version >> 8;
    const boot_version_minor = boot_version & 0x00_FF;

    // TODO(garrett): Be flexible and support older boot protocol versions.
    if (boot_version_major != 2 or boot_version_minor < 15) return error.UnsupportedBootConfiguration;

    const is_loaded_to_high_memory = (header_pointer.*.boot_protocol_flags & (1 << 0)) == 1;
    if (!is_loaded_to_high_memory) return error.UnsupportedBootConfiguration;

    const has_legacy_x64_entry_point = (header_pointer.*.extended_boot_protocol_flags & (1 << 0)) == 1;
    if (!has_legacy_x64_entry_point) return error.UnsupportedBootConfiguration;

    const two_mib = 2 * 1024 * 1024;
    const is_two_mib_aligned = header_pointer.*.kernel_alignment == two_mib;
    if (!is_two_mib_aligned) return error.UnsupportedBootConfiguration;

    const preferred_address = header_pointer.*.preferred_loading_address;
    if (preferred_address != high_memory_load_address and preferred_address != 0) return error.UnsupportedBootConfiguration;

    const is_relocatable = header_pointer.*.is_kernel_relocatable != 0;
    if (preferred_address == 0 and !is_relocatable) return error.InvalidHeader;

    var setup_sectors: usize = header_pointer.*.setup_sector_count;
    if (setup_sectors == 0) setup_sectors = 4;

    // NOTE(garrett): There's always an extra first sector to initially boot from.
    setup_sectors += 1;

    const setup_sector_length = setup_sectors * 512;
    const code_length = kernel.len -| setup_sector_length;
    if (code_length <= x64_entrypoint_offset) return error.InvalidHeader;
    if (code_length > header_pointer.*.initialization_size) return error.InvalidHeader;

    return .{
        .header = header_pointer.*,
        .image = kernel[setup_sector_length..],
    };
}

pub const linux_x64_boot_gdt: [4]gdt.Entry = .{
    gdt.Entry{
        .segment_descriptor = gdt.SegmentDescriptor.nullEntry(),
    },
    gdt.Entry{
        .segment_descriptor = gdt.SegmentDescriptor.nullEntry(),
    },
    gdt.Entry{
        .segment_descriptor = gdt.SegmentDescriptor{
            .limit_low = 0xFFFF,
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
            .limit_high = 0xF,
            .flags = gdt.Flags{
                .available = 0,
                .is_long_mode = 1,
                .is_32_bit = 0,
                .is_limit_in_page_granularity = 1,
            },
            .base_high = 0,
        },
    },
    gdt.Entry{
        .segment_descriptor = gdt.SegmentDescriptor{
            .limit_low = 0xFFFF,
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
            .limit_high = 0xF,
            .flags = gdt.Flags{
                .available = 0,
                .is_long_mode = 0,
                .is_32_bit = 1,
                .is_limit_in_page_granularity = 1,
            },
            .base_high = 0,
        },
    },
};

comptime {
    if (@sizeOf(@TypeOf(linux_x64_boot_gdt)) > alloc.page_size) {
        @compileError("If the Linux x64 GDT exceeds a page, our layout calculations need to be updated.");
    }
}

pub const KernelMemoryLayout = struct {
    boot_gdt_address: u64 = 0x1000,
    zero_page_address: u64 = 0x2000,
    command_line_address: u64 = 0x3000,
    stack_page_address: u64 = 0x4000,
    pml4_address: u64 = 0x5000,
    kernel_load_address: u64 = high_memory_load_address,
    initramfs_address: u64,
};

pub fn initializeGuestMemory(
    memory: guest.Memory,
    layout: KernelMemoryLayout,
    kernel: BootableKernel,
    initramfs: []const u8,
) void {
    const memory_bytes = @as([*]u8, @ptrFromInt(memory.host_physical_start));
    const guest_gdt: [*]gdt.Entry = @ptrFromInt(@intFromPtr(&memory_bytes[0]) + layout.boot_gdt_address);
    @memcpy(guest_gdt[0..linux_x64_boot_gdt.len], linux_x64_boot_gdt[0..]);

    const kernel_start = layout.kernel_load_address;
    const kernel_end = kernel_start + kernel.image.len;
    @memcpy(memory_bytes[kernel_start..kernel_end], kernel.image);

    const initramfs_start = layout.initramfs_address;
    const initramfs_end = initramfs_start + initramfs.len;
    @memcpy(memory_bytes[initramfs_start..initramfs_end], initramfs);

    const kernel_header_start = kernel_header_offset + layout.zero_page_address;
    const kernel_header_end = kernel_header_start + @sizeOf(KernelHeader);
    @memcpy(memory_bytes[kernel_header_start..kernel_header_end], std.mem.asBytes(&kernel.header));

    const e820_entry_count: *u8 = @ptrFromInt(
        memory.host_physical_start + layout.zero_page_address + e820_count_zero_page_offset,
    );

    e820_entry_count.* = 2;

    var e820_entries: [*]E820Entry = @ptrFromInt(
        memory.host_physical_start + layout.zero_page_address + e820_array_zero_page_offset,
    );

    e820_entries[0] = E820Entry{
        .base_address = 0,
        .size = layout.kernel_load_address,
        .type = @intFromEnum(E820RegionType.reserved),
    };

    e820_entries[1] = E820Entry{
        .base_address = layout.kernel_load_address,
        .size = (memory.page_count * alloc.page_size) - layout.kernel_load_address,
        .type = @intFromEnum(E820RegionType.usable),
    };

    // TODO(garrett): Make this more flexible and bounds check when we do as we must be under the header's
    // command line size which this hardcoded example should not exceed.
    const command_line: []const u8 = "earlycon=uart8250,io,0x3F8 console=ttyS0,115200 rdinit=/init";
    const command_line_end = layout.command_line_address + command_line.len;
    @memcpy(memory_bytes[layout.command_line_address..command_line_end], command_line);

    // TODO(garrett): We can safely cast these because we've artifically limited our memory allocation for VMs
    // down to 1GiB at max. When this changes, we'll need to be more careful here.
    const guest_kernel_header: *align(1) KernelHeader = @ptrFromInt(memory.host_physical_start + kernel_header_start);
    guest_kernel_header.bootloader_identifier = 0xFF;
    guest_kernel_header.command_line_pointer = @intCast(layout.command_line_address);
    guest_kernel_header.*.ramdisk_load_address = @intCast(initramfs_start);
    guest_kernel_header.*.ramdisk_size = @intCast(initramfs.len);

    // NOTE(garrett): Since Linux is going to remap its own tables, we can be lazy and make everything
    // read/write to start with.
    const pml4_start = memory.host_physical_start + layout.pml4_address;
    const pdpt_start = pml4_start + @sizeOf(paging.PageMapLevel4Table);
    const pdt_start = pdpt_start + @sizeOf(paging.PageDirectoryPointerTable);
    const pt_start = pdt_start + @sizeOf(paging.PageDirectoryTable);

    var pt: *paging.PageTable = @ptrFromInt(pt_start);
    var page_table_index: usize = 0;
    var page_directory_index: usize = 0;

    const pdt: *paging.PageDirectoryTable = @ptrFromInt(pdt_start);
    pdt[0].page_table_address = @truncate((pt_start - memory.host_physical_start) >> 12);
    pdt[0]._low = paging.present | paging.read_write;

    for (0..memory.page_count) |page_index| {
        if (page_table_index == 512) {
            page_table_index = 0;
            page_directory_index += 1;

            pt = @ptrFromInt(@intFromPtr(pt) + @sizeOf(paging.PageTable));
            pdt[page_directory_index].page_table_address = @truncate((@intFromPtr(pt) - memory.host_physical_start) >> 12);
            pdt[page_directory_index]._low = paging.present | paging.read_write;
        }

        pt[page_table_index].physical_address = @truncate((alloc.page_size * page_index) >> 12);
        pt[page_table_index]._low = paging.present | paging.read_write;

        page_table_index += 1;
    }

    const pdpt: *paging.PageDirectoryPointerTable = @ptrFromInt(pdpt_start);
    pdpt[0].page_directory_address = @truncate((@intFromPtr(pdt) - memory.host_physical_start) >> 12);
    pdpt[0]._low = paging.present | paging.read_write;

    const pml4: *paging.PageMapLevel4Table = @ptrFromInt(pml4_start);
    pml4[0].page_directory_pointer_address = @truncate((@intFromPtr(pdpt) - memory.host_physical_start) >> 12);
    pml4[0]._low = paging.present | paging.read_write;
}

pub fn launchState(layout: KernelMemoryLayout) guest_state.LaunchState {
    const guest_pml4_address = layout.pml4_address;

    const code_selector = gdt.SegmentSelector{
        .privilege_level = 0,
        .table_selector = 0,
        .table_index = 2,
    };

    const data_selector = gdt.SegmentSelector{
        .privilege_level = 0,
        .table_selector = 0,
        .table_index = 3,
    };

    var guest_cr0: guest_state.ControlRegister0 = @bitCast(@as(u64, 0));
    guest_cr0.protected_mode_enabled = 1;
    guest_cr0.monitor_coprocessor = 1;
    guest_cr0.extension_type = 1;
    guest_cr0.numeric_error = 1;
    guest_cr0.write_protect = 1;
    guest_cr0.paging = 1;

    var guest_cr4: guest_state.ControlRegister4 = @bitCast(@as(u64, 0));
    guest_cr4.physical_address_extension = 1;

    var guest_efer: guest_state.ExtendedFeatureEnablement = @bitCast(@as(u64, 0));
    guest_efer.long_mode_enable = 1;
    guest_efer.long_mode_active = 1;

    return .{
        .instruction_pointer = layout.kernel_load_address + x64_entrypoint_offset,
        // NOTE(garrett): In accordance with the x64 stack, we grow downward from the top of
        // the next page down to the start of our own.
        .stack_pointer = layout.stack_page_address + alloc.page_size,
        .flags = guest_state.Flags.initial(),

        .cr0 = @bitCast(guest_cr0),
        .cr3 = guest_pml4_address,
        .cr4 = @bitCast(guest_cr4),
        .efer = @bitCast(guest_efer),
        .gdtr = .{
            .base = layout.boot_gdt_address,
            .limit = @sizeOf(@TypeOf(linux_x64_boot_gdt)) - 1,
        },
        .idtr = .{
            .base = 0,
            .limit = 0,
        },
        .cs = guest_state.SegmentState.fromSelectorAndDescriptor(
            code_selector,
            linux_x64_boot_gdt[2].segment_descriptor,
        ),
        .ds = guest_state.SegmentState.fromSelectorAndDescriptor(
            data_selector,
            linux_x64_boot_gdt[3].segment_descriptor,
        ),
        .es = guest_state.SegmentState.fromSelectorAndDescriptor(
            data_selector,
            linux_x64_boot_gdt[3].segment_descriptor,
        ),
        .fs = .{
            .selector = .{
                .privilege_level = 0,
                .table_selector = 0,
                .table_index = 0,
            },
            .access_rights = @bitCast(@as(u16, 0)),
            .limit = 0,
            .base = 0,
        },
        .gs = .{
            .selector = .{
                .privilege_level = 0,
                .table_selector = 0,
                .table_index = 0,
            },
            .access_rights = @bitCast(@as(u16, 0)),
            .limit = 0,
            .base = 0,
        },
        .ss = guest_state.SegmentState.fromSelectorAndDescriptor(
            data_selector,
            linux_x64_boot_gdt[3].segment_descriptor,
        ),
        .general_purpose_registers = .{
            .rax = 0,
            .rbx = 0,
            .rcx = 0,
            .rdx = 0,
            .rdi = 0,
            .rsi = layout.zero_page_address,
            .rbp = 0,
            .r8 = 0,
            .r9 = 0,
            .r10 = 0,
            .r11 = 0,
            .r12 = 0,
            .r13 = 0,
            .r14 = 0,
            .r15 = 0,
        },
    };
}
