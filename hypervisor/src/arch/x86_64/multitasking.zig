pub const TaskStateSegment = packed struct(u832) {
    reserved1: u32,
    rsp0: u64,
    rsp1: u64,
    rsp2: u64,
    reserved2: u64,
    ist1: u64,
    ist2: u64,
    ist3: u64,
    ist4: u64,
    ist5: u64,
    ist6: u64,
    ist7: u64,
    reserved3: u64,
    reserved4: u16,
    io_bitmap_offset: u16,
};

pub const tss_size: usize = @bitSizeOf(TaskStateSegment) / 8;

comptime {
    if (tss_size != 104) {
        @compileError("The TSS on x86_64 CPUs must be 104 bytes in size.");
    }
}
