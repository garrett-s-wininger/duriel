const data_offset = 0x00;
const flag_offset = 0x18;
const integer_baud_rate_offset = 0x024;
const fractional_baud_rate_offset = 0x028;
const line_control_offset = 0x02C;
const control_offset = 0x030;
const interrupt_mask_set_clear_offset = 0x038;
const interrupt_clear_offset = 0x044;

const DataRegister = packed struct(u32) {
    char: u8,
    framing_error: u1,
    parity_error: u1,
    break_error: u1,
    overrun_error: u1,
    reserved: u20,
};

const FlagRegister = packed struct(u32) {
    clear_to_send: u1,
    data_set_ready: u1,
    data_carrier_detect: u1,
    busy: u1,
    rx_fifo_empty: u1,
    tx_fifo_full: u1,
    rx_fifo_full: u1,
    tx_fifo_empty: u1,
    ring_indicator: u1,
    reserved: u23,
};

const IntegerBaudRateRegister = packed struct(u32) {
    divisor: u16,
    reserved: u16,
};

const FractionalBaudRateRegister = packed struct(u32) {
    divisor: u6,
    reserved: u26,
};

const WordLength = enum(u2) {
    bits5 = 0b00,
    bits6 = 0b01,
    bits7 = 0b10,
    bits8 = 0b11,
};

const LineControlRegister = packed struct(u32) {
    send_break: u1,
    parity_enable: u1,
    even_parity: u1,
    two_stop_bits: u1,
    enable_fifos: u1,
    word_length: WordLength,
    stick_parity: u1,
    reserved: u24,
};

const ControlRegister = packed struct(u32) {
    enabled: u1,
    sir_enabled: u1,
    sir_low_power: u1,
    reserved1: u4,
    loopback_enable: u1,
    tx_enable: u1,
    rx_enable: u1,
    data_transmit_ready: u1,
    request_to_send: u1,
    out1: u1,
    out2: u1,
    rts_flow_control: u1,
    cts_flow_control: u1,
    reserved: u16,
};

const InterruptMaskSetClearRegister = packed struct(u32) {
    ri_mask: u1,
    cts_mask: u1,
    dcd_mask: u1,
    dsr_mask: u1,
    rx_mask: u1,
    tx_mask: u1,
    rx_timeout_mask: u1,
    framing_error_mask: u1,
    parity_error_mask: u1,
    break_error_mask: u1,
    overrun_error_mask: u1,
    reserved: u21,
};

pub fn Pl011(RegisterAccess: type) type {
    return struct {
        access: RegisterAccess,

        const Self = @This();

        pub fn init(_: *const Self, _: ?u16) void {
            // TODO(garrett): We'll need to configure this ourselves but, for now, UEFI has
            // the device set up properly. In order for us to take control, we'll have to
            // parse our device tree blob and identify the clock rate so we can set the
            // divisor appropriately.
        }

        pub fn read(self: *const Self, offset: usize) u32 {
            return self.access.read(offset);
        }

        pub fn write(self: *const Self, offset: usize, value: u32) void {
            self.access.write(offset, value);
        }

        pub fn putc(self: *const Self, char: u8) void {
            const register_data = DataRegister{
                .char = char,
                .framing_error = 0,
                .parity_error = 0,
                .break_error = 0,
                .overrun_error = 0,
                .reserved = 0,
            };

            while (true) {
                const flags: FlagRegister = @bitCast(self.read(flag_offset));
                if (flags.tx_fifo_full == 0) break;
            }

            self.write(data_offset, @bitCast(register_data));
        }
    };
}
