const alloc = @import("../allocation.zig");
const cpuid = @import("cpuid.zig");
const gdt = @import("gdt.zig");
const guest = @import("../../guest.zig");
const guest_state = @import("guest_state.zig");
const inst = @import("inst.zig");
const paging = @import("paging.zig");
const std = @import("std");

pub const vendor_string = "AuthenticAMD";

const processor_model_and_feature_ids = 0x0000_0001;
const msr_feature_bit = (1 << 5);

const extended_processor_feature_ids = 0x8000_0001;
const svm_feature_bit = (1 << 2);

const vm_cr_msr = 0xC001_0114;
const svm_disabled_bit = (1 << 4);

const efer_msr = 0xC000_0080;
const svm_enable_bit = (1 << 12);

const vm_host_save_address_msr = 0xC001_0117;

const svm_available_features = 0x8000_000A;
const nested_paging_bit = (1 << 0);
const next_instruction_pointer_bit = (1 << 3);

pub const VmExitCode = enum(i64) {
    invalid_guest_state = -1,
    cpuid = 0x72,
    halt = 0x78,
    nested_page_fault = 0x400,
};

const NestedPagingControl = packed struct(u64) {
    is_nested_paging_enabled: u1,
    _reserved: u63,
};

const InterceptBlock1 = packed struct(u32) {
    _reserved1: u18,
    cpuid: u1,
    _reserved2: u5,
    hlt: u1,
    _reserved3: u7,
};

const InterceptBlock2 = packed struct(u32) {
    vmrun: u1,
    _reserved: u31,
};

const Segment = packed struct(u128) {
    selector: u16,
    attribute: u16,
    limit: u32,
    base: u64,
};

const VirtualMachineControlBlock = struct {
    const total_size = 4096;
    const saved_state_boundary = 0x400;

    const Self = @This();

    raw: *[Self.total_size]u8,

    fn ptr(self: Self, comptime offset: usize, comptime T: type) *T {
        comptime if ((offset + @sizeOf(T)) > Self.total_size) {
            @compileError("Requested offset/type would be outside of VMCB memory");
        };

        return @ptrCast(@alignCast(self.raw[offset..][0..@sizeOf(T)]));
    }

    fn savedStatePtr(self: Self, comptime offset: usize, comptime T: type) *T {
        return self.ptr(offset + Self.saved_state_boundary, T);
    }

    fn asid(self: Self) *u32 {
        return self.ptr(0x058, u32);
    }

    fn attributeFromSegmentDescriptor(descriptor: gdt.SegmentDescriptor) u16 {
        const segment_flags: u4 = @bitCast(descriptor.flags);
        const access_value: u8 = @bitCast(descriptor.access);
        return @as(u16, access_value) | (@as(u16, segment_flags) << 8);
    }

    fn cpl(self: Self) *u8 {
        return self.savedStatePtr(0x0CB, u8);
    }

    fn cr0(self: Self) *u64 {
        return self.savedStatePtr(0x158, u64);
    }

    fn cr3(self: Self) *u64 {
        return self.savedStatePtr(0x150, u64);
    }

    fn cr4(self: Self) *u64 {
        return self.savedStatePtr(0x148, u64);
    }

    fn cs(self: Self) *Segment {
        return self.savedStatePtr(0x010, Segment);
    }

    fn ds(self: Self) *Segment {
        return self.savedStatePtr(0x030, Segment);
    }

    fn efer(self: Self) *u64 {
        return self.savedStatePtr(0x0D0, u64);
    }

    fn es(self: Self) *Segment {
        return self.savedStatePtr(0x000, Segment);
    }

    fn fs(self: Self) *Segment {
        return self.savedStatePtr(0x040, Segment);
    }

    fn exit_code(self: Self) *u64 {
        return self.ptr(0x070, u64);
    }

    fn exit_info1(self: Self) *u64 {
        return self.ptr(0x078, u64);
    }

    fn exit_info2(self: Self) *u64 {
        return self.ptr(0x080, u64);
    }

    fn gs(self: Self) *Segment {
        return self.savedStatePtr(0x050, Segment);
    }

    fn nested_cr3(self: Self) *u64 {
        return self.ptr(0x0B0, u64);
    }

    fn nested_paging(self: Self) *NestedPagingControl {
        return self.ptr(0x090, NestedPagingControl);
    }

    fn fillFromCurrentCpu(self: Self, efer_override: u64) void {
        vmsave(@intFromPtr(self.raw));

        self.asid().* = 1;
        self.interceptBlock1().*.cpuid = 1;
        self.interceptBlock1().*.hlt = 1;
        self.interceptBlock2().*.vmrun = 1;
        self.efer().* = efer_override;
        self.cpl().* = 0;
        self.cr0().* = inst.readCr0();
        self.cr3().* = inst.readCr3();
        self.cr4().* = inst.readCr4();
        self.flags().* = inst.readFlags();
        self.rsp().* = inst.readStackPointer();

        var gdt_register: inst.DescriptorTableRegister = undefined;
        inst.readGlobalDescriptorTableRegister(&gdt_register);

        self.gdtr().* = .{
            .selector = 0,
            .attribute = 0,
            .limit = gdt_register.limit,
            .base = gdt_register.base,
        };

        const descriptor_table = gdt.DescriptorTable{
            .base_address = gdt_register.base,
            .entries = (gdt_register.limit + 1) / @sizeOf(gdt.SegmentDescriptor),
        };

        const code_segment_selector: gdt.SegmentSelector = @bitCast(inst.readCodeSegment());
        const data_segment_selector: gdt.SegmentSelector = @bitCast(inst.readDataSegment());
        const extra_segment_selector: gdt.SegmentSelector = @bitCast(inst.readExtraSegment());
        const stack_segment_selector: gdt.SegmentSelector = @bitCast(inst.readStackSegment());
        const selectors = [_]gdt.SegmentSelector{
            code_segment_selector,
            data_segment_selector,
            extra_segment_selector,
            stack_segment_selector,
        };

        for (selectors) |selector| {
            if (selector.table_selector == 1) {
                @panic("Encountered selector for local descriptor, rather than global");
            }
        }

        fillSegment(self.cs(), descriptor_table, code_segment_selector);
        fillSegment(self.ds(), descriptor_table, data_segment_selector);
        fillSegment(self.es(), descriptor_table, extra_segment_selector);
        fillSegment(self.ss(), descriptor_table, stack_segment_selector);

        var idt_register: inst.DescriptorTableRegister = undefined;
        inst.readInterruptDescriptorTableRegister(&idt_register);

        self.idtr().* = .{ .selector = 0, .attribute = 0, .limit = idt_register.limit, .base = idt_register.base };
    }

    fn fillSegment(segment_address: *Segment, descriptor_table: gdt.DescriptorTable, segment_selector: gdt.SegmentSelector) void {
        const segment_descriptor = descriptor_table.descriptorAtIndex(segment_selector.table_index);

        segment_address.* = Segment{
            .selector = @bitCast(segment_selector),
            .attribute = attributeFromSegmentDescriptor(segment_descriptor.*),
            .limit = segment_descriptor.limit(),
            .base = segment_descriptor.base(),
        };
    }

    fn flags(self: Self) *u64 {
        return self.savedStatePtr(0x170, u64);
    }

    fn gdtr(self: Self) *Segment {
        return self.savedStatePtr(0x060, Segment);
    }

    fn idtr(self: Self) *Segment {
        return self.savedStatePtr(0x080, Segment);
    }

    fn interceptBlock1(self: Self) *InterceptBlock1 {
        return self.ptr(0x00C, InterceptBlock1);
    }

    fn interceptBlock2(self: Self) *InterceptBlock2 {
        return self.ptr(0x010, InterceptBlock2);
    }

    fn next_rip(self: Self) *u64 {
        return self.ptr(0x0C8, u64);
    }

    fn rax(self: Self) *u64 {
        return self.savedStatePtr(0x1F8, u64);
    }

    fn rip(self: Self) *u64 {
        return self.savedStatePtr(0x178, u64);
    }

    fn rsp(self: Self) *u64 {
        return self.savedStatePtr(0x1D8, u64);
    }

    fn ss(self: Self) *Segment {
        return self.savedStatePtr(0x020, Segment);
    }
};

fn vmrunEntry() callconv(.naked) void {
    // NOTE(garrett): This assumes the MSFT x64 calling conventions. The VMCB and save state area do
    // not allow us to set general purpose registers (except RAX + RSP). In order to be able to set
    // these, we take them from the guest register configuration after pushing our host registers
    // onto the stack. Once we exit, host registers are restored so we can resume execution.
    //
    // TODO(garrett): Preserve the more advanced floating-point operation registers like YMM and
    // ZMM which are only available based on feature support in the CPU as well as guest x87/XMM
    // and XCR0 state.
    asm volatile (
        \\
        \\ subq $520, %%rsp
        \\ fxsave64 (%%rsp)
        \\
        \\ pushq %%rbx
        \\ pushq %%rbp
        \\ pushq %%rdi
        \\ pushq %%rsi
        \\ pushq %%r12
        \\ pushq %%r13
        \\ pushq %%r14
        \\ pushq %%r15
        \\
        \\ pushq %%rdx
        \\ pushq %%rcx
        \\
        \\ movq 8(%%rsp), %%rax
        \\ movq 8(%%rax), %%rbx
        \\ movq 16(%%rax), %%rcx
        \\ movq 24(%%rax), %%rdx
        \\ movq 32(%%rax), %%rdi
        \\ movq 40(%%rax), %%rsi
        \\ movq 48(%%rax), %%rbp
        \\ movq 56(%%rax), %%r8
        \\ movq 64(%%rax), %%r9
        \\ movq 72(%%rax), %%r10
        \\ movq 80(%%rax), %%r11
        \\ movq 88(%%rax), %%r12
        \\ movq 96(%%rax), %%r13
        \\ movq 104(%%rax), %%r14
        \\ movq 112(%%rax), %%r15
        \\ movq (%%rsp), %%rax
        \\
        \\ vmrun
        \\
        \\ movq 8(%%rsp), %%rax
        \\ movq %%rbx, 8(%%rax)
        \\ movq %%rcx, 16(%%rax)
        \\ movq %%rdx, 24(%%rax)
        \\ movq %%rdi, 32(%%rax)
        \\ movq %%rsi, 40(%%rax)
        \\ movq %%rbp, 48(%%rax)
        \\ movq %%r8, 56(%%rax)
        \\ movq %%r9, 64(%%rax)
        \\ movq %%r10, 72(%%rax)
        \\ movq %%r11, 80(%%rax)
        \\ movq %%r12, 88(%%rax)
        \\ movq %%r13, 96(%%rax)
        \\ movq %%r14, 104(%%rax)
        \\ movq %%r15, 112(%%rax)
        \\
        \\ addq $16, %%rsp
        \\ popq %%r15
        \\ popq %%r14
        \\ popq %%r13
        \\ popq %%r12
        \\ popq %%rsi
        \\ popq %%rdi
        \\ popq %%rbp
        \\ popq %%rbx
        \\
        \\ fxrstor64 (%%rsp)
        \\ addq $520, %%rsp
        \\
        \\ retq
    );
}

fn vmrun(vmcb_address: u64, registers: *guest_state.GeneralPurposeRegisters) void {
    const entry: *const fn (
        u64,
        *guest_state.GeneralPurposeRegisters,
    ) callconv(.c) void = @ptrCast(&vmrunEntry);

    entry(vmcb_address, registers);
}

fn vmsave(save_address: u64) void {
    asm volatile (
        \\ vmsave
        :
        : [save_address] "{rax}" (save_address),
    );
}

pub const VmExit = struct {
    code: u64,
    info1: u64,
    info2: u64,
};

pub const Backend = struct {
    max_standard_func: u32,
    max_extended_func: u32,
    vmcb: ?VirtualMachineControlBlock = null,
    general_purpose_registers: ?guest_state.GeneralPurposeRegisters = null,

    const Self = @This();

    pub fn areRequiredFeaturesPresent(self: Self) bool {
        if (self.max_extended_func < svm_available_features) return false;

        const svm_features = cpuid.query(svm_available_features, 0);
        const nested_paging = svm_features.edx & nested_paging_bit;
        const next_rip = svm_features.edx & next_instruction_pointer_bit;

        // NOTE(garrett): We can get by without either of these acceleration
        // features. For simplicitly, we require them to avoid handling the
        // missing case where we'd have to do heavy manual management of the
        // guest CPU state.
        if ((nested_paging != 0) and (next_rip != 0)) {
            return true;
        }

        return false;
    }

    pub fn isVirtualizationDisabled(_: Self) bool {
        const vm_cr = inst.rdmsr(vm_cr_msr);
        return (vm_cr & svm_disabled_bit) != 0;
    }

    pub fn isVirtualizationSupported(self: Self) bool {
        if (self.max_standard_func < processor_model_and_feature_ids) return false;

        const standard_feature_information = cpuid.query(processor_model_and_feature_ids, 0);
        const msr_enabled = (standard_feature_information.edx & msr_feature_bit) != 0;

        if (!msr_enabled) return false;
        if (self.max_extended_func < extended_processor_feature_ids) return false;

        const extended_feature_information = cpuid.query(extended_processor_feature_ids, 0);
        const svm_enabled = (extended_feature_information.ecx & svm_feature_bit) != 0;

        return svm_enabled;
    }

    fn prepareNestedPageTables(pml4_start: u64, instance: guest.Memory) u64 {
        const base_page_table_pages = 3;
        const memory_map_pages = base_page_table_pages + (std.math.divCeil(
            usize,
            instance.page_count,
            512,
        ) catch unreachable);

        const tables = @as(
            [*]align(alloc.page_size) u8,
            @ptrFromInt(pml4_start),
        )[0 .. memory_map_pages * alloc.page_size];

        @memset(tables, 0);

        const page_directory_pointer_start = pml4_start + alloc.page_size;
        const page_directory_table_start = pml4_start + (2 * alloc.page_size);
        const page_table_start = pml4_start + (3 * alloc.page_size);

        // NOTE(garrett): Nested page table walks are considered user accesses and so
        // must be granted user permissions in order for them to be accessible when
        // the walk occurs.
        const npt_read_write = paging.present | paging.user_accessible | paging.read_write;

        const pdt: *paging.PageDirectoryTable = @ptrFromInt(page_directory_table_start);
        pdt[0].page_table_address = @truncate(page_table_start >> 12);
        pdt[0]._low = npt_read_write;

        // TODO(garrett): Formulate a method for more trusted workloads, such that the guest cannot modify its
        // page tables to change its own code regions.
        var pt: *paging.PageTable = @ptrFromInt(page_table_start);
        var page_directory_table_entry_index: usize = 0;
        var page_table_entry_index: usize = 0;

        for (0..instance.page_count) |idx| {
            if (page_table_entry_index == 512) {
                page_table_entry_index = 0;
                page_directory_table_entry_index += 1;
                pt = @ptrFromInt(@intFromPtr(pt) + @sizeOf(paging.PageTable));

                pdt[page_directory_table_entry_index].page_table_address = @truncate(page_table_start + (page_directory_table_entry_index * @sizeOf(paging.PageTable)) >> 12);
                pdt[page_directory_table_entry_index]._low = npt_read_write;
            }

            pt[page_table_entry_index].physical_address = @truncate(instance.host_physical_start + (idx * alloc.page_size) >> 12);
            pt[page_table_entry_index]._low = npt_read_write;

            page_table_entry_index += 1;
        }

        const pdpt: *paging.PageDirectoryPointerTable = @ptrFromInt(page_directory_pointer_start);
        pdpt[0].page_directory_address = @truncate(page_directory_table_start >> 12);
        pdpt[0]._low = npt_read_write;

        const pml4: *paging.PageMapLevel4Table = @ptrFromInt(pml4_start);
        pml4[0].page_directory_pointer_address = @truncate(page_directory_pointer_start >> 12);
        pml4[0]._low = npt_read_write;

        return pml4_start;
    }

    fn applySegment(source: guest_state.SegmentState, destination: *Segment) void {
        destination.* = .{
            .selector = @bitCast(source.selector),
            .attribute = @bitCast(source.access_rights),
            .limit = source.limit,
            .base = source.base,
        };
    }

    pub fn prepareVirtualization(
        self: *Self,
        allocation_start_address: u64,
        instance: guest.Instance,
        launch_state: guest_state.LaunchState,
    ) void {
        const efer = inst.rdmsr(efer_msr);
        const svm_enabled_efer = efer | svm_enable_bit;
        inst.wrmsr(efer_msr, svm_enabled_efer);

        const host_save_area: *[4096]u8 = @ptrFromInt(allocation_start_address);
        @memset(host_save_area, 0);
        inst.wrmsr(vm_host_save_address_msr, @intFromPtr(host_save_area));

        const vm_control_block_address: *[4096]u8 = @ptrFromInt(allocation_start_address + 4096);
        @memset(vm_control_block_address, 0);

        const control_block: VirtualMachineControlBlock = .{ .raw = vm_control_block_address };
        control_block.fillFromCurrentCpu(svm_enabled_efer);
        control_block.efer().* = launch_state.efer | svm_enable_bit;
        control_block.flags().* = @bitCast(launch_state.flags);

        control_block.gdtr().* = .{
            .selector = 0,
            .attribute = 0,
            .limit = launch_state.gdtr.limit,
            .base = launch_state.gdtr.base,
        };

        control_block.idtr().* = .{
            .selector = 0,
            .attribute = 0,
            .limit = launch_state.idtr.limit,
            .base = launch_state.idtr.base,
        };

        control_block.rax().* = launch_state.general_purpose_registers.rax;
        control_block.rip().* = launch_state.instruction_pointer;
        control_block.rsp().* = launch_state.stack_pointer;
        control_block.cr0().* = launch_state.cr0;
        control_block.cr3().* = launch_state.cr3;
        control_block.cr4().* = launch_state.cr4;

        applySegment(launch_state.cs, control_block.cs());
        applySegment(launch_state.ds, control_block.ds());
        applySegment(launch_state.es, control_block.es());
        applySegment(launch_state.fs, control_block.fs());
        applySegment(launch_state.gs, control_block.gs());
        applySegment(launch_state.ss, control_block.ss());

        control_block.nested_cr3().* = prepareNestedPageTables(
            (allocation_start_address + (2 * alloc.page_size)),
            instance.memory,
        );

        control_block.nested_paging().* = NestedPagingControl{ .is_nested_paging_enabled = 1, ._reserved = 0 };
        self.vmcb = control_block;
        self.general_purpose_registers = launch_state.general_purpose_registers;
    }

    fn interceptCpuid(vmcb: VirtualMachineControlBlock, registers: *guest_state.GeneralPurposeRegisters) void {
        // TODO(garrett): Support nRIP-incompatible CPUs
        vmcb.rip().* = vmcb.next_rip().*;

        // NOTE(garrett): Duriel's hypervisor detection specification. RAX is the greatest value
        // in the reserved range that's valid wihle RBX/RCX/RDX provide our hypervisor name.
        if (registers.rax == 0x4000_0000) {
            vmcb.rax().* = 0x4000_0000;
            registers.rax = 0x4000_0000;
            registers.rbx = std.mem.readInt(u32, "Duri", .little);
            registers.rcx = std.mem.readInt(u32, "el  ", .little);
            registers.rdx = std.mem.readInt(u32, "    ", .little);
            return;
        }

        // NOTE(garrett): These CPUID leaves are in the reserved hypervisor range. We zero them
        // to prevent leaking state for KVM, Xen, Hyper-V, etc.
        if (registers.rax > 0x4000_0000 and registers.rax < 0x5000_0000) {
            vmcb.rax().* = 0;
            registers.rax = 0;
            registers.rbx = 0;
            registers.rcx = 0;
            registers.rdx = 0;
            return;
        }

        var cpuid_data = cpuid.query(@truncate(registers.rax), @truncate(registers.rcx));

        // NOTE(garrett): Match Hyper-V's hypervisor presence detection.
        if (registers.rax == 1) {
            cpuid_data.ecx |= (1 << 31);
        }

        vmcb.rax().* = cpuid_data.eax;
        registers.rax = cpuid_data.eax;
        registers.rbx = cpuid_data.ebx;
        registers.rcx = cpuid_data.ecx;
        registers.rdx = cpuid_data.edx;
    }

    pub fn runGuest(self: *Self) VmExit {
        const vmcb = self.vmcb orelse @panic("VMCB not prepared");
        const registers = if (self.general_purpose_registers) |*regs|
            regs
        else
            @panic("Guest registers not prepared");

        var is_final_exit = false;

        while (!is_final_exit) {
            vmrun(@intFromPtr(vmcb.raw), registers);
            registers.rax = vmcb.rax().*;

            switch (vmcb.exit_code().*) {
                @intFromEnum(VmExitCode.cpuid) => interceptCpuid(vmcb, registers),
                else => is_final_exit = true,
            }
        }

        return .{
            .code = vmcb.exit_code().*,
            .info1 = vmcb.exit_info1().*,
            .info2 = vmcb.exit_info2().*,
        };
    }
};
