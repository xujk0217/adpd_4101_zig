const adpd = @import("adpd4101.zig");

pub const oscillator = adpd.Oscillator.INTERNAL_1MHZ;
pub const timeslot_freq_hz: u32 = 1000;
pub const i2c_device_path = "/dev/i2c-3";
pub const device_address: u8 = 0x24;
pub const use_ext_clock = false;
pub const time_slots = [_]adpd.TimeSlot{
    .{
        .id = "A",
        .leds = &[_]adpd.Led{
            .{
                .id = adpd.get_led_id("1A"),
                .current = 0x007F,
            },
        },
        .data_format = .{}, // default
        .led_pulse = .{}, // default
    },
};
