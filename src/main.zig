const std = @import("std");
const linux = @import("std").os.linux;
const sensor = @import("sensors/sensor.zig");
const i2c = @import("utils/i2c.zig");

pub fn main() !void {
    var adpd4101_sensor = sensor.ADPD4101Sensor.init("/dev/i2c-3") catch |err| {
        std.debug.print("Failed to initialize ADPD4101 sensor: {}\n", .{err});
        return err;
    };

    defer adpd4101_sensor.deinit();

    var read_buffer: [1024]u8 = undefined;
    while (true) {
        const bytes_read = try adpd4101_sensor.read_raw(&read_buffer);
        if (bytes_read > 0) {
            std.debug.print("Read {} bytes from ADPD4101 sensor\n", .{bytes_read});
        }
    }
}
