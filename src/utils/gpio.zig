const std = @import("std");
const linux = @import("std").os.linux;

pub fn get_gpio_id(comptime bank: u8, comptime group: u8, comptime number: u8) u32 {
    comptime {
        if (group < 'A' or group > 'D') @compileError("Group must be between 'A' and 'D'");
        if (bank > 4 or bank < 0) @compileError("Bank must be between 0 and 4");
        if (number > 7 or number < 0) @compileError("Number must be between 0 and 7");

        return (bank * 32 + ((group - 'A') * 8 + number));
    }
}

pub const GPIO = struct {
    pin_id: u32,
    fd: std.posix.fd_t,

    pub fn init(comptime pin_id: u32) !GPIO {
        // std.debug.print("Exported GPIO pin {d}\n", .{pin_id});
        const export_file = try std.fs.cwd().openFile("/sys/class/gpio/export", .{ .mode = .write_only });

        var write_buf: [32]u8 = undefined;
        const slice_buf = std.fmt.bufPrint(&write_buf, "{d}\n", .{pin_id}) catch {
            return error.FmtError;
        };
        try export_file.writeAll(slice_buf);
        defer export_file.close();

        // sleep for a short time to allow sysfs to create the gpio directory
        // std.Thread.sleep(100000000);

        var file_path_buf: [64]u8 = undefined;

        const input_path = std.fmt.bufPrint(&file_path_buf, "/sys/class/gpio/gpio{d}/value", .{pin_id}) catch {
            return error.FmtError;
        };

        const fd = try std.fs.cwd().openFile(input_path, .{ .mode = .read_write });

        // set the direction to input
        const direction_path = std.fmt.bufPrint(&file_path_buf, "/sys/class/gpio/gpio{d}/direction", .{pin_id}) catch {
            return error.FmtError;
        };
        const direction_file = try std.fs.cwd().openFile(direction_path, .{ .mode = .write_only });
        try direction_file.writeAll("in\n");
        defer direction_file.close();

        // set the edge to rising
        const edge_path = std.fmt.bufPrint(&file_path_buf, "/sys/class/gpio/gpio{d}/edge", .{pin_id}) catch {
            return error.FmtError;
        };
        const edge_file = try std.fs.cwd().openFile(edge_path, .{ .mode = .write_only });
        try edge_file.writeAll("rising\n");
        defer edge_file.close();

        return GPIO{
            .pin_id = pin_id,
            .fd = fd.handle,
        };
    }

    pub fn deinit(self: *GPIO) !void {
        std.posix.close(self.fd);
        const unexport_file = try std.fs.cwd().openFile("/sys/class/gpio/unexport", .{ .mode = .write_only });

        var write_buf: [32]u8 = undefined;
        const slice_buf = std.fmt.bufPrint(&write_buf, "{d}\n", .{self.pin_id}) catch {
            return error.FmtError;
        };

        try unexport_file.writeAll(slice_buf);
    }

    pub fn waitForInterrupt(self: *GPIO) !void {
        var poll_fd = [_]linux.pollfd{.{
            .fd = self.fd,
            .events = std.os.linux.POLL.PRI | std.os.linux.POLL.ERR,
            .revents = 0,
        }};

        _ = linux.poll(&poll_fd, 1, -1);

        // Clear the interrupt by reading the value
        if (poll_fd[0].revents & std.posix.POLL.PRI != 0) {
            var buf: [8]u8 = undefined;
            _ = try std.posix.lseek_SET(self.fd, 0);

            _ = try std.posix.read(self.fd, &buf);
        }
    }
};
