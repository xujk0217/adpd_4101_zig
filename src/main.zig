const std = @import("std");
const linux = @import("std").os.linux;
const sensor = @import("sensors/sensor.zig");
const i2c = @import("utils/i2c.zig");
const adpd_config = @import("sensors/adpd4101_config.zig");
const gpio = @import("utils/gpio.zig");
const constant = @import("constant.zig");

var queue_mutex = std.Thread.Mutex{};

var should_exit = std.atomic.Value(bool).init(false);
var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
var data_queue: std.ArrayList(u8) = undefined;

var stdout_buffer: [1024]u8 = undefined;
var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
const stdout = &stdout_writer.interface;

var stderr_buffer: [1024]u8 = undefined;
var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
const stderr = &stderr_writer.interface;

fn handle_signal(signum: c_int) callconv(.c) void {
    _ = signum;
    should_exit.store(true, .seq_cst);
}

fn process_data_queue() void {
    var timeslot_signal_size_arr: [adpd_config.time_slots.len]usize = undefined;

    inline for (adpd_config.time_slots, 0..) |slot, i| {
        timeslot_signal_size_arr[i] = @intCast(slot.data_format.sig_size);
    }

    var current_slot_index: usize = 0;

    while (!should_exit.load(.seq_cst)) {
        queue_mutex.lock();
        if (data_queue.items.len > 0) {
            const data = data_queue.items;
            var data_index: usize = 0;

            while (data_index < data.len) {
                const size = timeslot_signal_size_arr[current_slot_index];
                if (data_index + size > data.len) {
                    break;
                }
                const signal_data_raw = data[data_index .. data_index + size];
                var signal_value: u32 = 0;

                switch (size) {
                    1 => {
                        signal_value = @as(u32, signal_data_raw[0]);
                    },
                    2 => {
                        signal_value = @as(u32, signal_data_raw[0]) | (@as(u32, signal_data_raw[1]) << 8);
                    },
                    3 => {
                        signal_value = (@as(u32, signal_data_raw[1]) << 8) | @as(u32, signal_data_raw[0]) | (@as(u32, signal_data_raw[2]) << 16);
                    },
                    4 => {
                        signal_value = (@as(u32, signal_data_raw[0]) << 8) | @as(u32, signal_data_raw[1]) | (@as(u32, signal_data_raw[2]) << 16) | (@as(u32, signal_data_raw[3]) << 24);
                    },
                    else => {
                        unreachable;
                    },
                }

                // stdout.print("original data {any}\n", .{signal_data_raw}) catch |err| {
                //     stderr.print("Error writing to stdout: {}\n", .{err}) catch {};
                // };

                const casted_value: i64 = @intCast(signal_value);
                const timestamp = std.time.milliTimestamp();

                stdout.print("{d}, {d}\n", .{ casted_value - 8192, timestamp }) catch |err| {
                    stderr.print("Error writing to stdout: {}\n", .{err}) catch {};
                };

                data_index += size;
                current_slot_index = (current_slot_index + 1) % adpd_config.time_slots.len;
            }

            stdout.flush() catch |err| {
                stderr.print("Error flushing stdout: {}\n", .{err}) catch {};
            };

            data_queue.replaceRange(gpa.allocator(), 0, data_index, &[_]u8{}) catch |err| {
                stderr.print("Error removing processed data from queue: {}\n", .{err}) catch {};
            };
        }
        queue_mutex.unlock();
    }
}

fn read_data_loop(adpd_sensor: *sensor.ADPD4101Sensor, interrupt_gpio: *gpio.GPIO) void {
    while (!should_exit.load(.seq_cst)) {
        interrupt_gpio.waitForInterrupt() catch |err| {
            stderr.print("Error waiting for GPIO interrupt: {}\n", .{err}) catch {};
            return;
        };
        const read_data = adpd_sensor.read_raw() catch |err| {
            stderr.print("Error reading data from ADPD4101 sensor: {}\n", .{err}) catch {};
            continue;
        };

        if (read_data.len == 0) {
            continue;
        }

        queue_mutex.lock();
        for (read_data) |byte| {
            data_queue.append(gpa.allocator(), byte) catch |err| {
                stderr.print("Error appending data to queue: {}\n", .{err}) catch {};
            };
        }

        queue_mutex.unlock();
    }
}

pub fn main() !void {
    const act = linux.Sigaction{
        .handler = .{ .handler = handle_signal },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(linux.SIG.INT, &act, null);

    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    data_queue = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer data_queue.deinit(allocator);

    var adpd4101_sensor = sensor.ADPD4101Sensor.init(
        adpd_config.i2c_device_path,
        adpd_config.device_address,
        adpd_config.oscillator,
        adpd_config.timeslot_freq_hz,
        &adpd_config.time_slots,
        adpd_config.use_ext_clock,
        adpd_config.fifo_threshold,
        adpd_config.gpio_id,
    ) catch |err| {
        // std.debug.print("Failed to initialize ADPD4101 sensor: {}\n", .{err});
        return err;
    };

    defer adpd4101_sensor.deinit();

    var interrupt_gpio = try gpio.GPIO.init(constant.interrupt_gpio_pin_id);
    defer interrupt_gpio.deinit() catch |err| {
        stderr.print("Failed to deinitialize GPIO: {}\n", .{err}) catch {};
    };
    // while (!should_exit.load(.seq_cst)) {
    //     try interrupt_gpio.waitForInterrupt();
    //     const read_data = try adpd4101_sensor.read_raw();

    //     queue_mutex.lock();

    //     data_queue.append(allocator, read_data) catch |err| {
    //         // std.debug.print("Error appending data to queue: {}\n", .{err});
    //     };
    // }

    const data_thread = try std.Thread.spawn(.{}, read_data_loop, .{ &adpd4101_sensor, &interrupt_gpio });
    defer data_thread.join();
    const process_thread = try std.Thread.spawn(.{}, process_data_queue, .{});
    defer process_thread.join();

    // const file = try std.fs.cwd().openFile("/dev/i2c-3", .{ .mode = .read_write });

    // const data: [2]u8 = [_]u8{ 0x12, 0x34 };

    // try i2c.i2cWriteReg(file.handle, 0x24, 0x0D, data);
    // const result = try i2c.I2cReadReg(file.handle, 0x24, 0x0D);
    // // std.debug.print("Read data: {x}\n", .{result});
}
