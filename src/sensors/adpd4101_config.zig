const adpd = @import("adpd4101.zig");
const gpio = @import("../utils/gpio.zig");

pub const oscillator = adpd.Oscillator.INTERNAL_1MHZ;
pub const timeslot_freq_hz: u32 = 1000;
pub const i2c_device_path = "/dev/i2c-3";
pub const device_address: u8 = 0x24;
pub const use_ext_clock = false;
pub const gpio_id: u32 = 0;
pub const fifo_threshold: u16 = 6;
pub const time_slots = [_]adpd.TimeSlot{
    .{
        .id = "A",
        .leds = &[_]adpd.Led{
            .{
                .id = adpd.get_led_id("1A"),
                .current = 0x0003,
            },
        },
        .data_format = .{
            .lit_size = 0x0,
            .sig_size = 0x3,
        }, // default
        .led_pulse = .{
            .pulse_width_us = 0x1,
        }, // default
        .input_pds = [2]?adpd.PD{
            .{
                .id = 1,
            },
            null,
        },
        .counts = .{
            .num_integrations = 0x8,
            .num_repeats = 0x1,
        },
    },
};
