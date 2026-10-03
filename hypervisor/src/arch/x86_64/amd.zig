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

const NestedPagingControl = packed struct(u64) {
    is_nested_paging_enabled: u1,
    _reserved: u63,
};

const InterceptBlock1 = packed struct(u32) {
    _reserved1: u24,
    hlt: u1,
    _reserved2: u7,
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

fn vmrun(vmcb_address: u64) void {
    asm volatile (
        \\ vmrun
        :
        : [vmcb_address] "{rax}" (vmcb_address),
        : .{ .memory = true });
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

    const Self = @This();

    pub fn isNestedPagingSupported(self: Self) bool {
        if (self.max_extended_func < svm_available_features) return false;

        const svm_features = cpuid.query(svm_available_features, 0);
        if ((svm_features.edx & nested_paging_bit) != 0) {
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
    }

    pub fn runGuest(self: Self) VmExit {
        const vmcb = self.vmcb orelse @panic("VMCB not prepared");
        vmrun(@intFromPtr(vmcb.raw));

        return .{
            .code = vmcb.exit_code().*,
            .info1 = vmcb.exit_info1().*,
            .info2 = vmcb.exit_info2().*,
        };
    }
};
