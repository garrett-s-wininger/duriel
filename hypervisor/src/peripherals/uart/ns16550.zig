const interrupt_offset = 1;
const fifo_control_offset = 2;
const line_control_offset = 3;
const modem_control_offset = 4;
const line_status_offset = 5;

const FifoControl = packed struct(u8) {
    enabled: u1,
    clear_rx: u1,
    clear_tx: u1,
    dma_selection: u1,
    reserved: u2,
    interrupt_level: u2,
};

const InterruptTriggerLevel = enum(u2) {
    byte1 = 0b00,
    bytes4 = 0b01,
    bytes8 = 0b10,
    bytes14 = 0b11,
};

const DataConfiguration = enum(u2) {
    bits5 = 0b00,
    bits6 = 0b01,
    bits7 = 0b10,
    bits8 = 0b11,
};

const LineControl = packed struct(u8) {
    data: u2,
    stop: u1,
    parity: u3,
    is_break_enabled: u1,
    is_divisor_latch_enabled: u1,
};

const LineStatus = packed struct(u8) {
    data_ready: u1,
    overrun_error: u1,
    parity_error: u1,
    framing_error: u1,
    break_indicator: u1,
    transmission_buffer_empty: u1,
    transmitter_empty: u1,
    impending_error: u1,
};

const ModemControl = packed struct(u8) {
    data_terminal_ready: u1,
    request_to_send: u1,
    out1: u1,
    out2: u1,
    loop: u1,
    reserved1: u1,
    reserved2: u1,
    reserved3: u1,
};

pub fn Ns16550(comptime RegisterAccess: type) type {
    return struct {
        access: RegisterAccess,

        const Self = @This();

        fn read(self: *const Self, offset: usize) u8 {
            return self.access.read(offset);
        }

        fn write(self: *const Self, offset: usize, value: u8) void {
            self.access.write(offset, value);
        }

        fn configure_8n1(self: @This()) void {
            const configuration = LineControl{
                .data = @intFromEnum(DataConfiguration.bits8),
                .stop = 0,
                .parity = 0,
                .is_break_enabled = 0,
                .is_divisor_latch_enabled = 0,
            };

            self.write(line_control_offset, @bitCast(configuration));
        }

        fn configure_fifo(self: @This()) void {
            const configuration = FifoControl{
                .enabled = 1,
                .clear_rx = 1,
                .clear_tx = 1,
                .dma_selection = 0,
                .reserved = 0,
                .interrupt_level = @intFromEnum(InterruptTriggerLevel.bytes14),
            };

            self.write(fifo_control_offset, @bitCast(configuration));
        }

        fn configure_modem_control(self: @This()) void {
            const configuration = ModemControl{
                .data_terminal_ready = 1,
                .request_to_send = 1,
                .out1 = 0,
                .out2 = 1,
                .loop = 0,
                .reserved1 = 0,
                .reserved2 = 0,
                .reserved3 = 0,
            };

            self.write(modem_control_offset, @bitCast(configuration));
        }

        fn disable_interrupts(self: @This()) void {
            self.write(interrupt_offset, 0);
        }

        fn enable_divisor_latch(self: @This()) void {
            const configuration = LineControl{
                .data = 0,
                .stop = 0,
                .parity = 0,
                .is_break_enabled = 0,
                .is_divisor_latch_enabled = 1,
            };

            self.write(line_control_offset, @bitCast(configuration));
        }

        fn set_divisor(self: @This(), divisor: u16) void {
            self.write(0, @truncate(divisor));
            self.write(interrupt_offset, @truncate(divisor >> 8));
        }

        pub fn init(self: @This(), divisor: ?u16) void {
            // TODO(garrett): Probe for device presence and fail soft if nothing is there
            // to avoid spinning forever in transmission calls.

            self.disable_interrupts();

            if (divisor) |value| {
                self.enable_divisor_latch();
                self.set_divisor(value);
            }

            self.configure_8n1();
            self.configure_fifo();
            self.configure_modem_control();
        }

        pub fn putc(self: @This(), char: u8) void {
            var status: LineStatus = undefined;

            while (true) {
                status = @bitCast(self.read(line_status_offset));
                if (status.transmission_buffer_empty == 1) break;
            }

            self.write(0, char);
        }
    };
}
