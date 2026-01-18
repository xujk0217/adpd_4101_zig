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
var data_queue: std.ArrayList([]const u8) = undefined;

fn handle_signal(signum: c_int) callconv(.c) void {
    _ = signum;
    should_exit.store(true, .seq_cst);
}

fn process_data_queue() void {
    while (!should_exit.load(.seq_cst)) {
        queue_mutex.lock();
        if (data_queue.items.len > 0) {
            const data = data_queue.items[0];

            var i: usize = 0;

            while (i + 9 <= data.len) : (i += 9) {
                const sig_val_firstbyte: u32 = @intCast(std.mem.readInt(u8, data[i + 3 ..][1..2], .big));
                const sig_val_secondbyte: u32 = @intCast(std.mem.readInt(u8, data[i + 3 ..][0..1], .big));
                const sig_val_thirdbyte: u32 = @intCast(std.mem.readInt(u8, data[i + 3 ..][2..3], .big));
                const sig_val: u32 = (sig_val_thirdbyte << 16) | (sig_val_secondbyte << 8) | sig_val_firstbyte;
                std.debug.print("Data value: {d}\n", .{sig_val});
            }

            _ = data_queue.orderedRemove(0);
        }
        queue_mutex.unlock();
    }
}

fn read_data_loop(adpd_sensor: *sensor.ADPD4101Sensor, interrupt_gpio: *gpio.GPIO) void {
    while (!should_exit.load(.seq_cst)) {
        interrupt_gpio.waitForInterrupt() catch |err| {
            std.debug.print("Error waiting for GPIO interrupt: {}\n", .{err});
            return;
        };
        const read_data = adpd_sensor.read_raw() catch |err| {
            std.debug.print("Error reading data: {}\n", .{err});
            continue;
        };

        if (read_data.len == 0) {
            continue;
        }

        queue_mutex.lock();
        data_queue.append(gpa.allocator(), read_data) catch |err| {
            std.debug.print("Error appending data to queue: {}\n", .{err});
        };
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

    data_queue = try std.ArrayList([]const u8).initCapacity(allocator, 1024);
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
        std.debug.print("Failed to initialize ADPD4101 sensor: {}\n", .{err});
        return err;
    };

    defer adpd4101_sensor.deinit();

    var interrupt_gpio = try gpio.GPIO.init(constant.interrupt_gpio_pin_id);
    defer interrupt_gpio.deinit() catch |err| {
        std.debug.print("Failed to deinit GPIO: {}\n", .{err});
    };
    // while (!should_exit.load(.seq_cst)) {
    //     try interrupt_gpio.waitForInterrupt();
    //     const read_data = try adpd4101_sensor.read_raw();

    //     queue_mutex.lock();

    //     data_queue.append(allocator, read_data) catch |err| {
    //         std.debug.print("Error appending data to queue: {}\n", .{err});
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
    // std.debug.print("Read data: {x}\n", .{result});
}
