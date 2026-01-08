const std = @import("std");
const linux = @import("std").os.linux;
const sensor = @import("sensors/sensor.zig");
const i2c = @import("utils/i2c.zig");
const adpd_config = @import("sensors/adpd4101_config.zig");

var should_exit = std.atomic.Value(bool).init(false);

fn handle_signal(signum: c_int) callconv(.c) void {
    _ = signum;
    should_exit.store(true, .seq_cst);
}

pub fn main() !void {
    const act = linux.Sigaction{
        .handler = .{ .handler = handle_signal },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(linux.SIG.INT, &act, null);

    var adpd4101_sensor = sensor.ADPD4101Sensor.init(
        adpd_config.i2c_device_path,
        adpd_config.oscillator,
        adpd_config.timeslot_freq_hz,
        &adpd_config.time_slots,
        adpd_config.use_ext_clock,
    ) catch |err| {
        std.debug.print("Failed to initialize ADPD4101 sensor: {}\n", .{err});
        return err;
    };

    defer adpd4101_sensor.deinit();

    var read_buffer: [1024]u8 = undefined;
    while (!should_exit.load(.seq_cst)) {
        const bytes_read = try adpd4101_sensor.read_raw(&read_buffer);
        if (bytes_read > 0) {
            std.debug.print("Read data {any} bytes: \n", .{bytes_read});
        }
    }

    // const file = try std.fs.cwd().openFile("/dev/i2c-3", .{ .mode = .read_write });

    // const data: [2]u8 = [_]u8{ 0x12, 0x34 };

    // try i2c.i2cWriteReg(file.handle, 0x24, 0x0D, data);
    // const result = try i2c.I2cReadReg(file.handle, 0x24, 0x0D);
    // std.debug.print("Read data: {x}\n", .{result});
}
