pub const DescriptorTableRegister = packed struct(u80) {
    limit: u16,
    base: u64,
};

pub fn inb(port: u16) u8 {
    return asm volatile (
        \\ inb %[port], %[result]
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub fn loadGlobalDescriptorTable(address: *const DescriptorTableRegister) void {
    asm volatile (
        \\ lgdt (%[address])
        :
        : [address] "r" (address),
        : .{ .memory = true });
}

pub fn loadInterruptDescriptorTable(address: *const DescriptorTableRegister) void {
    asm volatile (
        \\ lidt (%[address])
        :
        : [address] "r" (address),
        : .{ .memory = true });
}

pub fn loadTaskRegister(selector: u16) void {
    asm volatile (
        \\ ltr %[selector]
        :
        : [selector] "r" (selector),
        : .{ .memory = true });
}

pub fn outb(port: u16, value: u8) void {
    asm volatile (
        \\ outb %[value], %[port]
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub fn reloadCodeSegment(selector: u64) void {
    asm volatile (
        \\ pushq %[selector]
        \\ leaq 1f(%%rip), %%rax
        \\ pushq %%rax
        \\ lretq
        \\ 1:
        :
        : [selector] "r" (selector),
        : .{ .memory = true, .rax = true, .rsp = true });
}

pub fn rdmsr(register: u32) u64 {
    var eax: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile (
        \\ rdmsr
        : [_] "={eax}" (eax),
          [_] "={edx}" (edx),
        : [register] "{ecx}" (register),
    );

    return (@as(u64, edx) << 32) | eax;
}

pub fn readCodeSegment() u16 {
    return asm volatile (
        \\ movw %%cs, %[out]
        : [out] "=r" (-> u16),
    );
}

pub fn readCr0() u64 {
    return asm volatile (
        \\ movq %%cr0, %[out]
        : [out] "=r" (-> u64),
    );
}

pub fn readCr2() u64 {
    return asm volatile (
        \\ movq %%cr2, %[out]
        : [out] "=r" (-> u64),
    );
}

pub fn readCr3() u64 {
    return asm volatile (
        \\ movq %%cr3, %[out]
        : [out] "=r" (-> u64),
    );
}

pub fn readCr4() u64 {
    return asm volatile (
        \\ movq %%cr4, %[out]
        : [out] "=r" (-> u64),
    );
}

pub fn readDataSegment() u16 {
    return asm volatile (
        \\ movw %%ds, %[out]
        : [out] "=r" (-> u16),
    );
}

pub fn readExtraSegment() u16 {
    return asm volatile (
        \\ movw %%es, %[out]
        : [out] "=r" (-> u16),
    );
}

pub fn readFlags() u64 {
    return asm volatile (
        \\ pushfq
        \\ popq %[out]
        : [out] "=r" (-> u64),
        :
        : .{ .rsp = true });
}

pub fn readGlobalDescriptorTableRegister(address: *DescriptorTableRegister) void {
    var value: DescriptorTableRegister = undefined;

    asm volatile (
        \\ sgdt %[value]
        : [value] "=m" (value),
    );

    address.* = value;
}

pub fn readInterruptDescriptorTableRegister(address: *DescriptorTableRegister) void {
    var value: DescriptorTableRegister = undefined;

    asm volatile (
        \\ sidt %[value]
        : [value] "=m" (value),
    );

    address.* = value;
}

pub fn readStackPointer() u64 {
    return asm volatile (
        \\ movq %%rsp, %[out]
        : [out] "=r" (-> u64),
    );
}

pub fn readStackSegment() u16 {
    return asm volatile (
        \\ movw %%ss, %[out]
        : [out] "=r" (-> u16),
    );
}

pub fn readTaskRegister() u16 {
    return asm volatile (
        \\ str %[out]
        : [out] "=r" (-> u16),
    );
}

pub fn setDataSegments(selector: u16) void {
    asm volatile (
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%ss
        :
        : [selector] "{ax}" (selector),
        : .{ .ds = true, .es = true, .rax = true, .ss = true });
}

pub fn writeCr3(value: u64) void {
    asm volatile (
        \\movq %[value], %%cr3
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

pub fn wrmsr(register: u32, value: u64) void {
    const low_order: u32 = @truncate(value);
    const high_order: u32 = @truncate(value >> 32);

    asm volatile (
        \\wrmsr
        :
        : [register] "{ecx}" (register),
          [high_order] "{edx}" (high_order),
          [low_order] "{eax}" (low_order),
    );
}
