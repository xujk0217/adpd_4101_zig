const adpd = @import("adpd4101.zig");
const gpio = @import("../utils/gpio.zig");

pub const oscillator = adpd.Oscillator.INTERNAL_1MHZ;
pub const timeslot_freq_hz: u32 = 10;
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
                .current = 0x007F,
            },
        },
        .data_format = .{
            .lit_size = 0x3,
            .sig_size = 0x3,
            .dark_size = 0x3,
        }, // default
        .led_pulse = .{}, // default
        .input_pds = [2]?adpd.PD{
            .{
                .id = 1,
            },
            null,
        },
    },
};
