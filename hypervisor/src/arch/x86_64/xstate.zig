const cpuid = @import("cpuid.zig");

pub const extended_state_enumeration_leaf = 0x0000_000D;
pub const media_extension_control_and_status_offset = 0x18;

pub const osxsave_cr4_bit = (1 << 18);

pub const xsave_supervisor_support_bit = (1 << 3);

// TODO(garrett): These reservations may not hold true on an Intel CPU
// and we may want to have this under AMD in some form.
pub const FeatureMask = packed struct(u64) {
    x87: u1 = 1,
    sse: u1,
    ymm: u1,
    reserved_1: u2 = 0,
    k: u1,
    zmm_0_15: u1,
    zmm_16_31: u1,
    reserved_2: u1 = 0,
    memory_protection_keys: u1,
    reserved_3: u52 = 0,
    lightweight_profiling: u1,
    reserved_4: u1 = 0,
};

pub const MediaExtensionControlAndStatus = packed struct(u32) {
    invalid_operation_exception: u1 = 0,
    denormalized_operand_exception: u1 = 0,
    zero_divide_exception: u1 = 0,
    overflow_exception: u1 = 0,
    underflow_exception: u1 = 0,
    precision_exception: u1 = 0,
    denormals_are_zero_mask: u1 = 0,
    invalid_operation_mask: u1 = 1,
    denormalized_operand_mask: u1 = 1,
    zero_divide_mask: u1 = 1,
    overflow_mask: u1 = 1,
    underflow_mask: u1 = 1,
    precision_mask: u1 = 1,
    rounding_control: u2 = 0,
    flush_to_zero: u1 = 0,
    reserved1: u1 = 0,
    misaligned_exception_mask: u1 = 0,
    reserved2: u14 = 0,
};

pub const ExtendedStateContext = extern struct {
    guest_save_state_address: u64,
    guest_xcr0: u64,
    host_save_state_address: u64,
    host_xcr0: u64,
    preservation_mask: FeatureMask,
};

comptime {
    if (@sizeOf(ExtendedStateContext) != 40) {
        @compileError("Expected ExtendedStateContext to have a size of 40 bytes");
    }

    if (@offsetOf(ExtendedStateContext, "guest_save_state_address") != 0) {
        @compileError("Expected guest_save_state_address offest of 0 bytes");
    }

    if (@offsetOf(ExtendedStateContext, "guest_xcr0") != 8) {
        @compileError("Expected guest_xcr0 offest of 8 bytes");
    }

    if (@offsetOf(ExtendedStateContext, "host_save_state_address") != 16) {
        @compileError("Expected host_save_state_address offest of 16 bytes");
    }

    if (@offsetOf(ExtendedStateContext, "host_xcr0") != 24) {
        @compileError("Expected host_xcr0 offest of 24 bytes");
    }

    if (@offsetOf(ExtendedStateContext, "preservation_mask") != 32) {
        @compileError("Expected preservation_mask offest of 32 bytes");
    }
}

pub const ExtendedStateMetadata = struct {
    supported_mask: FeatureMask,
    required_save_area_size: u64,
};

pub fn detect() ExtendedStateMetadata {
    const query_result = cpuid.query(extended_state_enumeration_leaf, 0);

    return .{
        .supported_mask = @bitCast((@as(u64, query_result.edx) << 32) | @as(u64, query_result.eax)),
        // NOTE(garrett): Technically we could use the save area size that's required for our enabled
        // CPU features (in this CPUID's EBX register result) versus our supported ones, but this
        // catch-all is a bit simpler, at least for now.
        .required_save_area_size = query_result.ecx,
    };
}

pub fn layoutSize(feature_mask: u64, compact: bool) usize {
    const x87_mmx_sse_save_size = 512;
    const header_size = 64;

    var space_required: usize = x87_mmx_sse_save_size + header_size;

    // NOTE(garrett): Bits 0/1 are already accounted for in the minimum save area
    // size as they're in the legacy FXSAVE image which forms the base of the
    // extended save area and are always present.
    for (2..63) |bit_index| {
        const test_mask = @as(u64, 1) << @as(u6, @intCast(bit_index));

        if ((feature_mask & test_mask) != 0) {
            const feature_size_data = cpuid.query(extended_state_enumeration_leaf, @intCast(bit_index));

            if (!compact) {
                const feature_end = @as(usize, feature_size_data.ebx) + feature_size_data.eax;
                space_required = @max(space_required, feature_end);
            } else {
                // NOTE(garrett): This currently assumes that no alignment padding is necessary which may
                // not always hold true.
                space_required += feature_size_data.eax;
            }
        }
    }

    return space_required;
}

// NOTE(garrett): Technically, and with the correct features, we can provide
// an ECX of 1 but with only XCR0 and no need for the bitmap, we just
// assume we want XCR0's value. Future CPUs may have XCR1+, that's a
// problem for a different day.
pub fn xgetbv() u64 {
    var xcr_low: u32 = undefined;
    var xcr_high: u32 = undefined;

    asm volatile (
        \\xgetbv
        : [xcr_low] "={eax}" (xcr_low),
          [xcr_high] "={edx}" (xcr_high),
        : [index] "{ecx}" (@as(u32, 0)),
        : .{});

    return (@as(u64, xcr_high) << 32) | @as(u64, xcr_low);
}
