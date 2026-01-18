const i2c = @import("../utils/i2c.zig");
const std = @import("std");

pub const ADPD4101 = struct {
    fd: std.posix.fd_t,
    dev_addr: u8,
    buffer: [1024]u8 = undefined,

    pub fn init(
        comptime i2c_bus_path: []const u8,
        comptime dev_addr: u8,
        comptime oscillator: Oscillator,
        comptime timeslot_freq_hz: u32,
        comptime timeslots: []const TimeSlot,
        comptime use_ext_clock: bool,
        comptime fifo_threshold: u16,
        comptime gpio_id: u32,
    ) !ADPD4101 {
        const file = try std.fs.cwd().openFile(i2c_bus_path, .{ .mode = .read_write });

        const fd = file.handle;

        try reset_all(fd, dev_addr);

        try set_oscillator(fd, dev_addr, oscillator, use_ext_clock);
        inline for (timeslots) |ts| {
            try config_time_slot(fd, dev_addr, ts);
        }
        try set_interrupt(fd, dev_addr, gpio_id, fifo_threshold);
        try set_time_slot_freq(fd, dev_addr, oscillator, timeslot_freq_hz);
        try set_opmode(fd, dev_addr, @intCast(timeslots.len), true);
        return ADPD4101{
            .fd = fd,
            .dev_addr = dev_addr,
        };
    }

    pub fn deinit(self: *ADPD4101) void {
        reset_all(self.fd, self.dev_addr) catch {
            // stderr.print("Failed to reset ADPD4101 during deinit: {}\n", .{err}) catch {};
        };
        std.posix.close(self.fd);
    }

    pub fn read_raw(self: *ADPD4101) ![]const u8 {
        // get fifo status
        const status = try i2c.I2cReadReg(self.fd, self.dev_addr, FIFO_STATUS_REG);
        // // std.debug.print("FIFO_STATUS_REG: {any}\n", .{status});
        const fifo_size: u16 = std.mem.readInt(u16, &status, .big) & 0b0000_0111_1111_1111;
        // // std.debug.print("FIFO size: {d}\n", .{fifo_size});
        if (fifo_size == 0) {
            return &[_]u8{};
        }

        const to_read: usize = @min(@as(usize, fifo_size), self.buffer.len);

        try i2c.i2cKeepReadReg(self.fd, self.dev_addr, FIFO_DATA_REG, self.buffer[0..to_read]);

        return self.buffer[0..to_read];
    }
};

fn set_opmode(fd: std.posix.fd_t, dev_addr: u8, slot_count: u8, is_enable: bool) !void {
    var mode: u16 = if (is_enable) 0b0000_0001 else 0b0000_0000;

    mode |= @as(u16, slot_count - 1) << 8;
    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, mode, .big);
    // std.debug.print("Setting OPMODE to {any}\n", .{data});
    try i2c.i2cWriteReg(fd, dev_addr, OPMODE_REG, @as([2]u8, data));
}

fn set_interrupt(fd: std.posix.fd_t, dev_addr: u8, gpio_id: u32, comptime fifo_threshold: u16) !void {
    comptime {
        if (fifo_threshold > 0x01FF) {
            @compileError("FIFO threshold must be less than or equal to 511");
        }
    }

    var data: [2]u8 = undefined;
    // set interrupt threshold for fifo
    std.mem.writeInt(u16, &data, fifo_threshold, .big);
    try i2c.i2cWriteReg(fd, dev_addr, FIFO_TH_REG, @as([2]u8, data));

    // set interrupt path to x
    const int_enable_x: u16 = 0b1000_0000_0000_0000;
    const target_gpio_reg = if (gpio_id < 2) GPIO_01_REG else GPIO_23_REG;

    std.mem.writeInt(u16, &data, int_enable_x, .big);
    try i2c.i2cWriteReg(fd, dev_addr, INT_ENABLE_XD_REG, @as([2]u8, data));
    // enable the gpio
    const enable_value: u16 = 0b010;
    // read the original gpio config

    var gpio_cfg_data = try i2c.I2cReadReg(fd, dev_addr, GPIO_CFG_REG);

    var gpio_cfg: u16 = std.mem.readInt(u16, &gpio_cfg_data, .big);
    const offset: u4 = @intCast((gpio_id % 2) * 3);
    gpio_cfg |= enable_value << offset;
    // write back the gpio config
    std.mem.writeInt(u16, &data, gpio_cfg, .big);
    try i2c.i2cWriteReg(fd, dev_addr, GPIO_CFG_REG, @as([2]u8, data));

    // config the gpio output
    // 0x02 mean interrupt x
    const gpio_set_value: u16 = 0x02;
    const gpio_value: u16 = gpio_set_value << (if (gpio_id % 2 == 0) 0 else 8);
    std.mem.writeInt(u16, &data, gpio_value, .big);
    try i2c.i2cWriteReg(fd, dev_addr, target_gpio_reg, @as([2]u8, data));
}

fn reset_all(fd: std.posix.fd_t, dev_addr: u8) !void {
    const data: [2]u8 = [_]u8{ 0b10000000, 0x00 };
    try i2c.i2cWriteReg(fd, dev_addr, SYS_CTL_REG, data);
}

fn set_oscillator(
    fd: std.posix.fd_t,
    dev_addr: u8,
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

    try i2c.i2cWriteReg(fd, dev_addr, SYS_CTL_REG, @as([2]u8, data));
}

fn config_time_slot(fd: std.posix.fd_t, dev_addr: u8, slot: TimeSlot) !void {
    const input_target_reg = INPUT_A_REG + (slot.id[0] - 'A') * 0x20;
    const ts_ctrl_target_reg = TS_CTRL_A_REG + (slot.id[0] - 'A') * 0x20;
    const data_format_target_reg = DATA_FORMAT_A_REG + (slot.id[0] - 'A') * 0x20;
    const lit_data_format_target_reg = LIT_DATA_FORMAT_A_REG + (slot.id[0] - 'A') * 0x20;
    const mod_pulse_target_reg = MOD_PULSE_A_REG + (slot.id[0] - 'A') * 0x20;
    const led_pow12_target_reg = LED_POW12_A_REG + (slot.id[0] - 'A') * 0x20;
    const led_pow34_target_reg = LED_POW34_A_REG + (slot.id[0] - 'A') * 0x20;
    const counts_target_reg = COUNTS_A_REG + (slot.id[0] - 'A') * 0x20;
    var input_value: u16 = 0;
    var ts_ctrl_value: u16 = 0;
    var data_format_value: u16 = 0;
    var lit_data_format_value: u16 = 0;
    var mod_pulse_value: u16 = 0;
    var led_pow12_value: u16 = 0;
    var led_pow34_value: u16 = 0;
    // buffer
    var data: [2]u8 = undefined;
    // channel1
    if (slot.input_pds[0]) |pd| {
        const offset: u4 = if (pd.id % 2 == 0)
            @as(u4, 2)
        else
            @as(u4, 0);

        const shift_amout: u4 = @intCast(((pd.id - 1) / 2) * 4 + offset);

        input_value |= @as(u16, 0x1) << shift_amout;
    }

    // channel2
    if (slot.input_pds[1]) |pd| {
        const offset: u4 = if (pd.id % 2 == 0)
            @as(u4, 2)
        else
            @as(u4, 1);
        const shift_amout: u4 = @intCast(((pd.id - 1) / 2) * 4 + offset);
        input_value |= @as(u16, 0x1) << shift_amout;
        // need to enable the 2nd channel
        ts_ctrl_value |= 0b0100_0000_0000_0000;
    }

    // std.debug.print("value binary: {b}\n", .{input_value});

    std.mem.writeInt(u16, &data, input_value, .big);
    // std.debug.print("Setting INPUT_{s} to {x}\n", .{ slot
    // .id, input_value });
    try i2c.i2cWriteReg(fd, dev_addr, input_target_reg, @as([2]u8, data));
    std.mem.writeInt(u16, &data, ts_ctrl_value, .big);
    // std.debug.print("Setting TS_CTRL_{s} to {x}\n", .{ slot.id, ts_ctrl_value });
    try i2c.i2cWriteReg(fd, dev_addr, ts_ctrl_target_reg, @as([2]u8, data));

    data_format_value |= @as(u16, slot.data_format.dark_shift & 0x0F) << 11;
    data_format_value |= @as(u16, slot.data_format.dark_size & 0x03) << 8;
    data_format_value |= @as(u16, slot.data_format.sig_shift & 0x0F) << 3;
    data_format_value |= @as(u16, slot.data_format.sig_size & 0x03);

    std.mem.writeInt(u16, &data, data_format_value, .big);
    // std.debug.print("Setting DATA_FORMAT_{s} to {b}\n", .{ slot.id, data_format_value });
    try i2c.i2cWriteReg(fd, dev_addr, data_format_target_reg, @as([2]u8, data));

    lit_data_format_value |= (slot.data_format.lit_shift & 0x0F) << 3;
    lit_data_format_value |= (slot.data_format.lit_size & 0x03);

    std.mem.writeInt(u16, &data, lit_data_format_value, .big);
    // std.debug.print("Setting LIT_DATA_FORMAT_{s} to {b}\n", .{ slot.id, lit_data_format_value });
    try i2c.i2cWriteReg(fd, dev_addr, lit_data_format_target_reg, @as([2]u8, data));

    mod_pulse_value |= (slot.led_pulse.pulse_width_us & 0xFF) << 8;
    mod_pulse_value |= (slot.led_pulse.pulse_offset_us & 0xFF);

    std.mem.writeInt(u16, &data, mod_pulse_value, .big);
    // std.debug.print("Setting MOD_PULSE_{s} to {b}\n", .{ slot.id, mod_pulse_value });
    try i2c.i2cWriteReg(fd, dev_addr, mod_pulse_target_reg, @as([2]u8, data));

    // configure LED power
    for (slot.leds) |led| {
        // std.debug.print("Configuring LED ID {d} with current {d}\n", .{ led.id, led.current });
        if (led.id < 4) {
            const shift: u4 = @intCast((led.id / 2) * 8);
            led_pow12_value |= (led.current & 0x7F) << shift;
            led_pow12_value |= @as(u16, led.id % 2) << (shift + 7);
        } else {
            const shift: u4 = @intCast(((led.id - 4) / 2) * 8);
            led_pow34_value |= (led.current & 0x7F) << shift;
            led_pow34_value |= @as(u16, led.id % 2) << (shift + 7);
        }
    }

    std.mem.writeInt(u16, &data, led_pow12_value, .big);
    // std.debug.print("Setting LED_POW12_{s} to {b}\n", .{ slot.id, led_pow12_value });
    try i2c.i2cWriteReg(fd, dev_addr, led_pow12_target_reg, @as([2]u8, data));
    std.mem.writeInt(u16, &data, led_pow34_value, .big);
    // std.debug.print("Setting LED_POW34_{s} to {b}\n", .{ slot.id, led_pow34_value });
    try i2c.i2cWriteReg(fd, dev_addr, led_pow34_target_reg, @as([2]u8, data));

    // configure counts
    var counts_value: u16 = 0;
    counts_value |= (slot.counts.num_integrations) << 8;
    counts_value |= (slot.counts.num_repeats);
    std.mem.writeInt(u16, &data, counts_value, .big);
    // std.debug.print("Setting COUNTS_{s} to {b}\n", .{ slot.id, counts_value });
    try i2c.i2cWriteReg(fd, dev_addr, counts_target_reg, @as([2]u8, data));
}

fn set_time_slot_freq(fd: std.posix.fd_t, dev_addr: u8, oscillator: Oscillator, target_hz: u32) !void {
    const oscillator_freq: u32 = switch (oscillator) {
        .INTERNAL_1MHZ => 1_000_000,
        .INTERNAL_32KHZ => 32_768,
    };

    const ts_freq: u32 = oscillator_freq / target_hz;
    const low_freq: u16 = @truncate(ts_freq & 0x0000FFFF);
    const high_freq: u16 = @truncate((ts_freq >> 16) & 0xFFFF);

    // std.debug.print("Setting time slot frequency to {any} Hz (low_freq: {x}, high_freq: {x})\n", .{ target_hz, low_freq, high_freq });

    var data: [2]u8 = undefined;
    std.mem.writeInt(u16, &data, low_freq, .big);
    // std.debug.print("Setting TS_FREQ to {any}\n", .{data});
    try i2c.i2cWriteReg(fd, dev_addr, TS_FREQ_REG, @as([2]u8, data));
    std.mem.writeInt(u16, &data, high_freq, .big);
    // std.debug.print("Setting TS_FREQH to {any}\n", .{data});
    try i2c.i2cWriteReg(fd, dev_addr, TS_FREQH_REG, @as([2]u8, data));
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

// Register Addresses
// global control registers
const OPMODE_REG: u16 = 0x0010;
const SYS_CTL_REG: u16 = 0x000F;
const FIFO_STATUS_REG: u16 = 0x0000;
const FIFO_DATA_REG: u16 = 0x002F;
const TS_FREQ_REG: u16 = 0x000D;
const TS_FREQH_REG: u16 = 0x000E;
const FIFO_TH_REG: u16 = 0x0006;
const INT_ENABLE_XD_REG: u16 = 0x0014;
const INT_ENABLE_YD_REG: u16 = 0x0015;
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
// ts ctrl register
const TS_CTRL_A_REG: u16 = 0x0100;
const TS_CTRL_B_REG: u16 = 0x0120;
const TS_CTRL_C_REG: u16 = 0x0140;
const TS_CTRL_D_REG: u16 = 0x0160;
const TS_CTRL_E_REG: u16 = 0x0180;
const TS_CTRL_F_REG: u16 = 0x01A0;
const TS_CTRL_G_REG: u16 = 0x01C0;
const TS_CTRL_H_REG: u16 = 0x01E0;
const TS_CTRL_I_REG: u16 = 0x0200;
const TS_CTRL_J_REG: u16 = 0x0220;
const TS_CTRL_K_REG: u16 = 0x0240;
const TS_CTRL_L_REG: u16 = 0x0260;
// ts pulse register
const MOD_PULSE_A_REG: u16 = 0x010C;
const MOD_PULSE_B_REG: u16 = 0x012C;
const MOD_PULSE_C_REG: u16 = 0x014C;
const MOD_PULSE_D_REG: u16 = 0x016C;
const MOD_PULSE_E_REG: u16 = 0x018C;
const MOD_PULSE_F_REG: u16 = 0x01AC;
const MOD_PULSE_G_REG: u16 = 0x01CC;
const MOD_PULSE_H_REG: u16 = 0x01EC;
const MOD_PULSE_I_REG: u16 = 0x020C;
const MOD_PULSE_J_REG: u16 = 0x022C;
const MOD_PULSE_K_REG: u16 = 0x024C;
const MOD_PULSE_L_REG: u16 = 0x026C;
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
// counts register
const COUNTS_A_REG: u16 = 0x0107;
const COUNTS_B_REG: u16 = 0x0127;
const COUNTS_C_REG: u16 = 0x0147;
const COUNTS_D_REG: u16 = 0x0167;
const COUNTS_E_REG: u16 = 0x0187;
const COUNTS_F_REG: u16 = 0x01A7;
const COUNTS_G_REG: u16 = 0x01C7;
const COUNTS_H_REG: u16 = 0x01E7;
const COUNTS_I_REG: u16 = 0x0207;
const COUNTS_J_REG: u16 = 0x0227;
const COUNTS_K_REG: u16 = 0x0247;
const COUNTS_L_REG: u16 = 0x0267;
// gpio register
const GPIO_CFG_REG: u16 = 0x0022;
const GPIO_01_REG: u16 = 0x0023;
const GPIO_23_REG: u16 = 0x0024;

pub const Oscillator = enum { INTERNAL_1MHZ, INTERNAL_32KHZ };

// struct definitions
pub const TimeSlot = struct {
    id: []const u8,
    leds: []const Led,
    counts: Counts,
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

pub const Counts = struct {
    num_integrations: u16 = 0x1,
    num_repeats: u16 = 0x1,
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
