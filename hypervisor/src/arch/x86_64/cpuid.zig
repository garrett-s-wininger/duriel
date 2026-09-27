const std = @import("std");

const Result = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32
};

const MaxStandardFuncAndVendor = struct {
    max_standard_func: u32,
    vendor: [12]u8,
};

pub fn query(leaf: u32, subleaf: u32) Result {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile(
        \\cpuid
        : [_] "={eax}" (eax), [_] "={ebx}" (ebx), [_] "={ecx}" (ecx), [_] "={edx}" (edx),
        : [leaf] "{eax}" (leaf), [subleaf] "{ecx}" (subleaf)
    );

    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}

pub fn max_standard_func_and_vendor() MaxStandardFuncAndVendor {
    const cpuid_result = query(0, 0);
    var result: MaxStandardFuncAndVendor = std.mem.zeroes(MaxStandardFuncAndVendor);

    result.max_standard_func = cpuid_result.eax;
    @memcpy(result.vendor[0..4], std.mem.asBytes(&cpuid_result.ebx));
    @memcpy(result.vendor[4..8], std.mem.asBytes(&cpuid_result.edx));
    @memcpy(result.vendor[8..12], std.mem.asBytes(&cpuid_result.ecx));

    return result;
}

pub fn max_extended_func() u32 {
    return query(0x8000_0000, 0).eax;
}
