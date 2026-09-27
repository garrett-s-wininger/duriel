const std = @import("std");

pub const SegmentSelector = packed struct(u16) {
    privilege_level: u2,
    table_selector: u1,
    table_index: u13,
};

pub const CodeAccess = packed struct(u4) {
    accessed: u1,
    readable: u1,
    conforming: u1,
    must_be_1: u1,
};

pub const DataAccess = packed struct(u4) {
    accessed: u1,
    writable: u1,
    expand_down: u1,
    must_be_0: u1,
};

pub const SystemAccess = enum(u4) {
    ldt = 0b0010,
    tss_available = 0b1001,
    tss_busy = 0b1011,
    call_gate = 0b1100,
    interrupt_gate = 0b1110,
    trap_gate = 0b1111,
};

pub const AccessType = packed union(u4) {
    code: CodeAccess,
    data: DataAccess,
    system: SystemAccess,
};

pub const AccessFlags = packed struct(u8) {
    type: AccessType,
    is_code_or_data: u1,
    descriptor_privilege_level: u2,
    present: u1,
};

pub const Flags = packed struct(u4) {
    available: u1,
    is_long_mode: u1,
    is_32_bit: u1,
    is_limit_in_page_granularity: u1,
};

pub const SegmentDescriptor = packed struct(u64) {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: AccessFlags,
    limit_high: u4,
    flags: Flags,
    base_high: u8,

    pub fn base(self: @This()) u64 {
        return self.base_low | (@as(u64, self.base_middle) << 16) | (@as(u64, self.base_high) << 24);
    }

    pub fn limit(self: @This()) u32 {
        var result: u32 = self.limit_low | (@as(u32, self.limit_high) << 16);

        if (self.flags.is_limit_in_page_granularity != 0) {
            result = (result << 12 | 0xFFF);
        }

        return result;
    }

    pub fn nullEntry() @This() {
        return .{
            .limit_low = 0,
            .base_low = 0,
            .base_middle = 0,
            .access = @bitCast(@as(u8, 0)),
            .limit_high = 0,
            .flags = @bitCast(@as(u4, 0)),
            .base_high = 0,
        };
    }
};

pub const SystemSegmentExpansion = packed struct(u64) {
    base_address_uppermost: u32,
    reserved1: u8,
    must_be_0: u5,
    reserved2: u19,
};

pub const Entry = packed union(u64) {
    segment_descriptor: SegmentDescriptor,
    system_segment_expansion: SystemSegmentExpansion,
};

pub const DescriptorTable = struct {
    base_address: u64,
    entries: u16,

    pub fn descriptorAtIndex(self: @This(), index: u16) *align(1) SegmentDescriptor {
        if (index >= self.entries) {
            @panic("Requested out of bounds descriptor index, cannot load from table");
        }

        return @ptrFromInt(self.base_address + (index * @sizeOf(SegmentDescriptor)));
    }
};
