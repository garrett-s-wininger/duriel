const std = @import("std");

const max_line = 80;

pub fn Logger(comptime Sink: type) type {
    return struct {
        var sink: ?*Sink = null;

        pub fn install(new_sink: *Sink) void {
            sink = new_sink;
        }

        pub fn logFn(
            comptime level: std.log.Level,
            comptime scope: @EnumLiteral(),
            comptime format: []const u8,
            args: anytype,
        ) void {
            // TODO(garrett): Implement fancier log message output.
            _ = level;
            _ = scope;

            if (sink == null) return;
            logFormatted(format, args);
        }

        pub fn log(message: []const u8) void {
            const output = sink orelse return;

            for (message) |char| {
                output.putc(char);
            }

            output.putc('\r');
            output.putc('\n');
        }

        pub fn logFormatted(comptime format: []const u8, args: anytype) void {
            var buffer: [max_line]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, format, args) catch {
                @panic("Log message exceeded capacity");
            };

            log(message);
        }
    };
}
