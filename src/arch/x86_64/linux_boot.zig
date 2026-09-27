const gdt = @import("gdt.zig");
const guest = @import("../../guest.zig");
const guest_state = @import("guest_state.zig");

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

pub fn launchState(memory: guest.Memory, translation_root: u64) guest_state.LaunchState {
    const guest_pml4_address = translation_root;
    const guest_gdt_address = guest_pml4_address - @sizeOf(@TypeOf(linux_x64_boot_gdt));
    const guest_gdt: [*]gdt.Entry = @ptrFromInt(memory.host_physical_start + guest_gdt_address);

    @memcpy(guest_gdt[0..linux_x64_boot_gdt.len], linux_x64_boot_gdt[0..]);

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
        .instruction_pointer = 0,
        // NOTE(garrett): Unlike a physical stack, the x64 stack grows downward so we
        // are always writing below the GDT and not into it.
        .stack_pointer = guest_gdt_address,
        .flags = guest_state.Flags.initial(),

        .cr0 = @bitCast(guest_cr0),
        .cr3 = guest_pml4_address,
        .cr4 = @bitCast(guest_cr4),
        .efer = @bitCast(guest_efer),
        .gdtr = .{
            .base = guest_gdt_address,
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
            .rsi = 0,
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
