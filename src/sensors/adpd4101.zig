const i2c = @import("../utils/i2c.zig");
const std = @import("std");

pub const ADPD4101 = struct {
    fd: std.posix.fd_t,

    pub fn init(i2c_bus_path: []const u8) !ADPD4101 {
        const file = try std.fs.cwd().openFile(i2c_bus_path, .{ .mode = .read_write });

        const fd = file.handle;

        try set_opmode(fd, SLOT_COUNT, true);
        try set_oscillator(fd, .INTERNAL_1MHZ, USE_EXT_CLOCK);
        try set_input(fd);
        try set_led_power(fd, &LED_IDS);
        return ADPD4101{
            .fd = fd,
        };
    }

    pub fn deinit(self: *ADPD4101) void {
        std.posix.close(self.fd);
    }

    pub fn read_raw(self: *const ADPD4101, out_buf: []u8) !usize {
        // get fifo status
        const status = try i2c.I2cReadReg(self.fd, DEV_ADDR, FIFO_STATUS_REG);
        const fifo_size = std.mem.readInt(u16, &status, .little) & 0b0000_0111_1111_1111;
        if (fifo_size == 0) {
            return 0;
        }

        const to_read: usize = @min(@as(usize, fifo_size) * 4, out_buf.len);

        try i2c.i2cKeepReadReg(self.fd, DEV_ADDR, FIFO_DATA_REG, out_buf[0..to_read]);

        return to_read;
    }
};

fn set_opmode(fd: std.posix.fd_t, slot_count: u8, is_enable: bool) !void {
    var mode: u16 = if (is_enable) 0b0000_0001 else 0b0000_0000;

    mode |= @as(u16, slot_count - 1) << 8;
    const data = std.mem.toBytes(mode);
    try i2c.i2cWriteReg(fd, DEV_ADDR, OPMODE_REG, @as([2]u8, data));
}

fn set_oscillator(
    fd: std.posix.fd_t,
    oscillator: Oscillator,
    use_ext_clock: bool,
) !void {
    if (use_ext_clock) {
        unreachable;
    }

    const sys_ctl: u16 = switch (oscillator) {
        .INTERNAL_1MHZ => 0b0000_0101,
        .INTERNAL_32KHZ => 0b0000_0000,
    };

    const data = std.mem.toBytes(sys_ctl);
    try i2c.i2cWriteReg(fd, DEV_ADDR, SYS_CTL_REG, @as([2]u8, data));
}

// TODO
fn set_led_power(fd: std.posix.fd_t, led_ids: []const u16) !void {
    _ = led_ids;
    const value: u16 = 0x0001;
    const data = std.mem.toBytes(value);
    try i2c.i2cWriteReg(fd, DEV_ADDR, LED_POW12_A_REG, @as([2]u8, data));
}

// TODO
fn set_input(fd: std.posix.fd_t) !void {
    const value: u16 = 0b0000_0001;
    const data = std.mem.toBytes(value);
    try i2c.i2cWriteReg(fd, DEV_ADDR, INPUT_A_REG, @as([2]u8, data));
}

// compile time function to get LED ID from name
fn get_led_id(comptime names: []const []const u8) [names.len]u16 {
    comptime {
        var result: [names.len]u16 = undefined;
        for (names, 0..) |name, i| {
            if (name.len != 2) {
                @compileError("LED name must be 2 characters long");
            }
            const number = name[0] - '0' - 1;
            const letter = name[1];

            result[i] = (number * 2 + (letter - 'A'));
        }
        return result;
    }
}
// ADPD4101 Constants
const SLOT_COUNT: u8 = 1;
const USE_EXT_CLOCK: bool = false;
const LED_IDS = get_led_id(&[_][]const u8{
    "1A",
});

// Device I2C Address
const DEV_ADDR: u8 = 0x24;

// Register Addresses
const OPMODE_REG: u16 = 0x0010;
const SYS_CTL_REG: u16 = 0x000F;
const FIFO_STATUS_REG: u16 = 0x0000;
const FIFO_DATA_REG: u16 = 0x002F;
// LED Power Registers
const LED_POW12_A_REG: u16 = 0x0105;
const LED_POW12_B_REG: u16 = 0x0125;
const LED_POW12_C_REG: u16 = 0x0145;
const LED_POW12_D_REG: u16 = 0x0165;
const LED_POW12_E_REG: u16 = 0x0185;
const LED_POW12_F_REG: u16 = 0x01A5;
const LED_POW12_G_REG: u16 = 0x01C5;
const LED_POW12_H_REG: u16 = 0x01E5;
const LED_POW12_I_REG: u16 = 0x0205;
const LED_POW12_J_REG: u16 = 0x0225;
const LED_POW12_K_REG: u16 = 0x0245;
const LED_POW12_L_REG: u16 = 0x0265;
const LED_POW34_A_REG: u16 = 0x0106;
const LED_POW34_B_REG: u16 = 0x0126;
const LED_POW34_C_REG: u16 = 0x0146;
const LED_POW34_D_REG: u16 = 0x0166;
const LED_POW34_E_REG: u16 = 0x0186;
const LED_POW34_F_REG: u16 = 0x01A6;
const LED_POW34_G_REG: u16 = 0x01C6;
const LED_POW34_H_REG: u16 = 0x01E6;
const LED_POW34_I_REG: u16 = 0x0206;
const LED_POW34_J_REG: u16 = 0x0226;
const LED_POW34_K_REG: u16 = 0x0246;
const LED_POW34_L_REG: u16 = 0x0266;
// input register
const INPUT_A_REG: u16 = 0x0102;
const INPUT_B_REG: u16 = 0x0122;
const INPUT_C_REG: u16 = 0x0142;
const INPUT_D_REG: u16 = 0x0162;
const INPUT_E_REG: u16 = 0x0182;
const INPUT_F_REG: u16 = 0x01A2;
const INPUT_G_REG: u16 = 0x01C2;
const INPUT_H_REG: u16 = 0x01E2;
const INPUT_I_REG: u16 = 0x0202;
const INPUT_J_REG: u16 = 0x0222;
const INPUT_K_REG: u16 = 0x0242;
const INPUT_L_REG: u16 = 0x0262;

const Oscillator = enum { INTERNAL_1MHZ, INTERNAL_32KHZ };
