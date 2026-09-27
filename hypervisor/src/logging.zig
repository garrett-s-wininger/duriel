const std = @import("std");

const max_line = 80;

pub fn Logger(comptime Sink: type) type {
    return struct {
        sink: *Sink,

        pub fn log(self: @This(), comptime message: []const u8) void {
            for (message) |char| {
                self.sink.putc(char);
            }

            self.sink.putc('\r');
            self.sink.putc('\n');
        }

        pub fn logFormatted(self: @This(), comptime format: []const u8, args: anytype) void {
            var buffer: [max_line]u8 = undefined;
            const message = std.fmt.bufPrint(&buffer, format, args) catch {
                return;
            };

            for (message) |char| {
                self.sink.putc(char);
            }

            self.sink.putc('\r');
            self.sink.putc('\n');
        }
    };
}
