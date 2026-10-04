const gdt = @import("gdt.zig");

pub const DescriptorTableState = struct {
    base: u64,
    limit: u16,
};

pub const GeneralPurposeRegisters = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
};

pub const ControlRegister0 = packed struct(u64) {
    protected_mode_enabled: u1,
    monitor_coprocessor: u1,
    emulate_coprocessor: u1,
    task_switched: u1,
    extension_type: u1 = 1,
    numeric_error: u1,
    reserved_1: u10 = 0,
    write_protect: u1,
    reserved_2: u1 = 0,
    alignment_mask: u1,
    reserved_3: u10 = 0,
    not_writethrough: u1,
    cache_disable: u1,
    paging: u1,
    reserved_4: u32 = 0,
};

pub const ControlRegister4 = packed struct(u64) {
    virtual_8086_extensions: u1,
    protected_mode_virtual_interrupts: u1,
    time_stamp_disable: u1,
    debugging_extensions: u1,
    page_size_extensions: u1,
    physical_address_extension: u1,
    machine_check_enable: u1,
    page_global_enable: u1,
    performance_monitoring_counter_enable: u1,
    os_fxsave_fxrstor_support: u1,
    os_unmasked_exception_support: u1,
    user_mode_instruction_prevention: u1,
    level_5_paging_enabled: u1,
    reserved_1: u3 = 0,
    fs_gs_base_support: u1,
    process_context_identifier_enable: u1,
    xsave_extended_states_enable: u1,
    reserved_2: u1 = 0,
    supervisor_mode_execution_prevention: u1,
    supervisor_mode_access_prevention: u1,
    protection_key_enable: u1,
    control_flow_enforcement_tech: u1,
    reserved_3: u40 = 0,
};

pub const ExtendedFeatureEnablement = packed struct(u64) {
    syscall_enable: u1,
    reserved_1: u7 = 0,
    long_mode_enable: u1,
    reserved_2: u1 = 0,
    long_mode_active: u1,
    no_execute_enable: u1,
    reserved_3: u52 = 0,
};

pub const SegmentAccessRights = packed struct(u16) {
    type: u4,
    is_code_or_data: u1,
    privilege_level: u2,
    present: u1,
    available: u1,
    is_long_mode: u1,
    is_32_bit: u1,
    is_limit_in_page_granularity: u1,
    reserved: u4 = 0,
};

pub const SegmentState = struct {
    selector: gdt.SegmentSelector,
    access_rights: SegmentAccessRights,
    limit: u32,
    base: u64,

    pub fn fromSelectorAndDescriptor(selector: gdt.SegmentSelector, descriptor: gdt.SegmentDescriptor) @This() {
        return .{
            .selector = selector,
            .access_rights = .{
                .type = @bitCast(descriptor.access.type),
                .is_code_or_data = descriptor.access.is_code_or_data,
                .privilege_level = descriptor.access.descriptor_privilege_level,
                .present = descriptor.access.present,
                .available = descriptor.flags.available,
                .is_long_mode = descriptor.flags.is_long_mode,
                .is_32_bit = descriptor.flags.is_32_bit,
                .is_limit_in_page_granularity = descriptor.flags.is_limit_in_page_granularity,
            },
            .limit = descriptor.limit(),
            .base = descriptor.base(),
        };
    }
};

pub const Flags = packed struct(u64) {
    carry: u1,
    must_be_1: u1,
    parity: u1,
    must_be_0_1: u1,
    auxiliary: u1,
    must_be_0_2: u1,
    zero: u1,
    sign: u1,
    trap: u1,
    interrupt: u1,
    direction: u1,
    overflow: u1,
    io_privilege_level: u2,
    nested_task: u1,
    must_be_0_3: u1,
    resume_from_breakpoint: u1,
    virtual_8086: u1,
    alignment_check: u1,
    virtual_interrupt: u1,
    virtual_interrupt_pending: u1,
    id: u1,
    reserved: u42,

    pub fn initial() @This() {
        return @bitCast(@as(u64, 0x2));
    }
};

pub const LaunchState = struct {
    instruction_pointer: u64,
    stack_pointer: u64,
    flags: Flags,
    cr0: u64,
    cr3: u64,
    cr4: u64,
    efer: u64,
    gdtr: DescriptorTableState,
    idtr: DescriptorTableState,
    cs: SegmentState,
    ds: SegmentState,
    es: SegmentState,
    fs: SegmentState,
    gs: SegmentState,
    ss: SegmentState,
    general_purpose_registers: GeneralPurposeRegisters,
};
