const inst = @import("inst.zig");

pub const invalid_opcode_vector = 6;
pub const general_protection_vector = 13;
pub const page_fault_vector = 14;

pub const InterruptAndTrapGate = packed struct(u128) {
    offset_low: u16,
    selector: u16,
    interrupt_stack_table: u3,
    reserved1: u5,
    type: u4,
    must_be_zero: u1,
    descriptor_privilege_level: u2,
    present: u1,
    offset_mid: u16,
    offset_high: u32,
    reserved2: u32,
};

pub const InterruptDescriptorTable = [256]InterruptAndTrapGate;

pub fn gateForAddress(selector: u16, address: u64) InterruptAndTrapGate {
    const interrupt_type: u4 = 0xE;

    return .{
        .offset_low = @truncate(address),
        .selector = selector,
        .interrupt_stack_table = 0,
        .reserved1 = 0,
        .type = interrupt_type,
        .must_be_zero = 0,
        .descriptor_privilege_level = 0,
        .present = 1,
        .offset_mid = @truncate(address >> 16),
        .offset_high = @truncate(address >> 32),
        .reserved2 = 0,
    };
}

pub const FaultInfo = struct {
    interrupt_vector: u8,
    instruction_pointer: u64,
    error_code: u64,
    fault_address: ?u64,
    register_flags: u64,
    stack_pointer: u64,
};

pub const FatalFaultHandler = *const fn (FaultInfo) noreturn;

// NOTE(garrett): These need a static lifetime in the output binary to be addressable by the CPU.
// We should treat these as initialized once and then constant for the lifetime of the hypervisor.
pub var fatal_fault_handler: FatalFaultHandler = undefined;
pub var interrupt_table: InterruptDescriptorTable = undefined;

pub fn defaultHandler() callconv(.naked) noreturn {
    asm volatile (
        \\unexpected_interrupt:
        \\  cli
        \\1:
        \\  hlt
        \\  jmp 1b
    );
}

pub fn generalProtectionFaultEntry() callconv(.naked) noreturn {
    asm volatile (
        \\movl $13, %%edx
        \\jmp errorCodeEntry
    );
}

pub fn invalidOpcodeEntry() callconv(.naked) noreturn {
    asm volatile (
        \\movl $6, %%edx
        \\jmp noErrorCodeEntry
    );
}

pub fn pageFaultEntry() callconv(.naked) noreturn {
    asm volatile (
        \\movl $14, %%edx
        \\jmp errorCodeEntry
    );
}

export fn noErrorCodeEntry() callconv(.naked) noreturn {
    // NOTE(garrett): We push a zero value so our interrupt stack is always 16-byte aligned since these
    // faults do not push an error code. This way, our dispatch code can always interact with
    // identical data.
    asm volatile (
        \\pushq $0
        \\jmp exceptionEntry
    );
}

export fn errorCodeEntry() callconv(.naked) noreturn {
    asm volatile (
        \\jmp exceptionEntry
    );
}

export fn exceptionEntry() callconv(.naked) noreturn {
    // NOTE(garrett): Since we're using UEFI, and by extension, Microsoft's x64 calling conventions,
    // we provide the interrupt frame as the first argument via RCX and provide additional space to
    // save RCX, RDX, R8, and R9 before jumping into our code.
    asm volatile (
        \\cld
        \\movq %%rsp, %%rcx
        \\subq $32, %%rsp
        \\callq exceptionDispatcher
    );
}

const InterruptFrame = extern struct {
    error_code: u64,
    instruction_pointer: u64,
    code_segment: u64,
    register_flags: u64,
    stack_pointer: u64,
    stack_segment: u64,
};

export fn exceptionDispatcher(interrupt_frame: *const InterruptFrame, interrupt_vector: u8) callconv(.c) noreturn {
    fatal_fault_handler(.{
        .interrupt_vector = interrupt_vector,
        .instruction_pointer = interrupt_frame.instruction_pointer,
        .error_code = interrupt_frame.error_code,
        .fault_address = if (interrupt_vector == page_fault_vector) inst.readCr2() else null,
        .register_flags = interrupt_frame.register_flags,
        .stack_pointer = interrupt_frame.stack_pointer,
    });
}

comptime {
    if (@sizeOf(InterruptAndTrapGate) != 16) @compileError("Interrupt and trap gates must be 16 bytes in size.");
    if (@sizeOf(InterruptDescriptorTable) != 4096) @compileError("IDT must be equal to an entire 4 Kib memory page in size.");

    if (@sizeOf(InterruptFrame) != 48) @compileError("x86_64 interrupt frame must be 48 bytes in size.");
    if (@offsetOf(InterruptFrame, "error_code") != 0x0) @compileError("Interrupt frame error code must be at 0x0.");
    if (@offsetOf(InterruptFrame, "instruction_pointer") != 0x8) @compileError("Interrupt instruction pointer must be at 0x8.");
    if (@offsetOf(InterruptFrame, "code_segment") != 0x10) @compileError("Interrupt frame code segment must be at 0x10.");
    if (@offsetOf(InterruptFrame, "register_flags") != 0x18) @compileError("Interrupt frame register flags must be at 0x18.");
    if (@offsetOf(InterruptFrame, "stack_pointer") != 0x20) @compileError("Interrupt frame stack pointer must be at 0x20.");
    if (@offsetOf(InterruptFrame, "stack_segment") != 0x28) @compileError("Interrupt frame stack segment must be at 0x28.");
}
