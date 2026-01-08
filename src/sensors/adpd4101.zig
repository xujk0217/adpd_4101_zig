const i2c = @import("../utils/i2c.zig");
const std = @import("std");

pub const ADPD4101 = struct {
    fd: std.posix.fd_t,

    pub fn init(
        comptime i2c_bus_path: []const u8,
        comptime oscillator: Oscillator,
        comptime timeslot_freq_hz: u32,
        comptime timeslots: []const TimeSlot,
        comptime use_ext_clock: bool,
    ) !ADPD4101 {
        const file = try std.fs.cwd().openFile(i2c_bus_path, .{ .mode = .read_write });

        const fd = file.handle;

        try reset_all(fd);

        try set_oscillator(fd, oscillator, use_ext_clock);
        try set_led_power(
            fd,
            timeslots,
        );
        inline for (timeslots) |ts| {
            try config_time_slot(fd, ts);
        }
        try set_time_slot_freq(fd, oscillator, timeslot_freq_hz);
        try set_opmode(fd, @intCast(timeslots.len), true);
        return ADPD4101{
            .fd = fd,
        };
    }

    pub fn deinit(self: *ADPD4101) void {
        reset_all(self.fd) catch |err| {
            std.debug.print("Failed to reset ADPD4101 during deinit: {}\n", .{err});
        };
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
    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, mode, .big);
    std.debug.print("Setting OPMODE to {any}\n", .{data});
    try i2c.i2cWriteReg(fd, DEV_ADDR, OPMODE_REG, @as([2]u8, data));
}

fn reset_all(fd: std.posix.fd_t) !void {
    const data: [2]u8 = [_]u8{ 0b10000000, 0x00 };
    try i2c.i2cWriteReg(fd, DEV_ADDR, SYS_CTL_REG, data);
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
        .INTERNAL_1MHZ => 0b0000_0110,
        .INTERNAL_32KHZ => 0b0000_0000,
    };

    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, sys_ctl, .big);

    try i2c.i2cWriteReg(fd, DEV_ADDR, SYS_CTL_REG, @as([2]u8, data));
}

fn config_time_slot(fd: std.posix.fd_t, slot: TimeSlot) !void {
    const target_reg = INPUT_A_REG + (slot.id[0] - 'A');

    var value: u16 = 0;

    // channel1
    if (slot.input_pds[0]) |pd| {
        const offset: u4 = if (pd.id % 2 == 0)
            @as(u4, 2)
        else
            @as(u4, 0);

        const shift_amout: u4 = @intCast(((pd.id - 1) / 2) * 4 + offset);

        value |= @as(u16, 0x1) << shift_amout;
    }

    // channel2
    if (slot.input_pds[1]) |pd| {
        const offset: u4 = if (pd.id % 2 == 0)
            @as(u4, 2)
        else
            @as(u4, 1);
        const shift_amout: u4 = @intCast(((pd.id - 1) / 2) * 4 + offset);
        value |= @as(u16, 0x1) << shift_amout;
    }

    std.debug.print("value binary: {b}\n", .{value});

    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, value, .big);
    std.debug.print("Setting INPUT_{s} to {x}\n", .{ slot
        .id, value });
    try i2c.i2cWriteReg(fd, DEV_ADDR, target_reg, @as([2]u8, data));
}

fn set_time_slot_freq(fd: std.posix.fd_t, oscillator: Oscillator, target_hz: u32) !void {
    const oscillator_freq: u32 = switch (oscillator) {
        .INTERNAL_1MHZ => 1_000_000,
        .INTERNAL_32KHZ => 32_768,
    };

    const ts_freq: u32 = oscillator_freq / target_hz;
    const low_freq: u16 = @truncate(ts_freq & 0x0000FFFF);
    const high_freq: u16 = @truncate((ts_freq >> 16) & 0xFFFF);

    std.debug.print("Setting time slot frequency to {any} Hz (low_freq: {x}, high_freq: {x})\n", .{ target_hz, low_freq, high_freq });

    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, low_freq, .big);
    std.debug.print("Setting TS_FREQ to {any}\n", .{data});
    try i2c.i2cWriteReg(fd, DEV_ADDR, TS_FREQ_REG, @as([2]u8, data));
    std.mem.writeInt(u16, &data, high_freq, .big);
    std.debug.print("Setting TS_FREQH to {any}\n", .{data});
    try i2c.i2cWriteReg(fd, DEV_ADDR, TS_FREQH_REG, @as([2]u8, data));
}

// TODO
fn set_led_power(fd: std.posix.fd_t, time_slots: []const TimeSlot) !void {
    _ = time_slots;
    const value: u16 = 0x007f;
    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, value, .big);
    std.debug.print("Setting LED power to {x}\n", .{value});
    try i2c.i2cWriteReg(fd, DEV_ADDR, LED_POW12_A_REG, @as([2]u8, data));
}

// compile time function to get LED ID from name
pub fn get_led_id(comptime name: []const u8) u16 {
    comptime {
        if (name.len != 2) {
            @compileError("LED name must be 2 characters long");
        }
        // to lower case
        if (name[1] < 'A' or name[1] > 'B') {
            @compileError("LED name second character must be A, B");
        }
        if (name[0] < '1' or name[0] > '4') {
            @compileError("LED name first character must be between 1 and 4");
        }
        const number = name[0] - '0' - 1;
        const letter = name[1];
        return (number * 2 + (letter - 'A'));
    }
}
// Device I2C Address
const DEV_ADDR: u8 = 0x24;

// Register Addresses
// global control registers
const OPMODE_REG: u16 = 0x0010;
const SYS_CTL_REG: u16 = 0x000F;
const FIFO_STATUS_REG: u16 = 0x0000;
const FIFO_DATA_REG: u16 = 0x002F;
const TS_FREQ_REG: u16 = 0x000D;
const TS_FREQH_REG: u16 = 0x000E;
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
// data format register
const DATA_FORMAT_A_REG: u16 = 0x0110;
const DATA_FORMAT_B_REG: u16 = 0x0130;
const DATA_FORMAT_C_REG: u16 = 0x0150;
const DATA_FORMAT_D_REG: u16 = 0x0170;
const DATA_FORMAT_E_REG: u16 = 0x0190;
const DATA_FORMAT_F_REG: u16 = 0x01B0;
const DATA_FORMAT_G_REG: u16 = 0x01D0;
const DATA_FORMAT_H_REG: u16 = 0x01F0;
const DATA_FORMAT_I_REG: u16 = 0x0210;
const DATA_FORMAT_J_REG: u16 = 0x0230;
const DATA_FORMAT_K_REG: u16 = 0x0250;
const DATA_FORMAT_L_REG: u16 = 0x0270;
const LIT_DATA_FORMAT_A_REG: u16 = 0x0111;
const LIT_DATA_FORMAT_B_REG: u16 = 0x0131;
const LIT_DATA_FORMAT_C_REG: u16 = 0x0151;
const LIT_DATA_FORMAT_D_REG: u16 = 0x0171;
const LIT_DATA_FORMAT_E_REG: u16 = 0x0191;
const LIT_DATA_FORMAT_F_REG: u16 = 0x01B1;
const LIT_DATA_FORMAT_G_REG: u16 = 0x01D1;
const LIT_DATA_FORMAT_H_REG: u16 = 0x01F1;
const LIT_DATA_FORMAT_I_REG: u16 = 0x0211;
const LIT_DATA_FORMAT_J_REG: u16 = 0x0231;
const LIT_DATA_FORMAT_K_REG: u16 = 0x0251;
const LIT_DATA_FORMAT_L_REG: u16 = 0x0271;

pub const Oscillator = enum { INTERNAL_1MHZ, INTERNAL_32KHZ };

// struct definitions
pub const TimeSlot = struct {
    id: []const u8,
    leds: []const Led,
    data_format: DataFormat,
    led_pulse: LedPulse,
    input_pds: [2]?PD,
};

pub const DataFormat = struct {
    dark_shift: u8 = 0x0,
    dark_size: u8 = 0x0,
    lit_shift: u8 = 0x0,
    lit_size: u8 = 0x3,
    sig_shift: u8 = 0x0,
    sig_size: u8 = 0x3,
};

pub const Led = struct {
    id: u16,
    current: u16,
};

pub const LedPulse = struct {
    pulse_width_us: u16 = 0x2,
    pulse_offset_us: u16 = 0x10,
};

pub const PD = struct {
    id: u16,
};
