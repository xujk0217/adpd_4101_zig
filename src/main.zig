const std = @import("std");
const linux = @import("std").os.linux;
const i2c = @import("utils/i2c.zig");

pub fn main() !void {
    const file = try std.fs.cwd().openFile("/dev/i2c-3", .{ .mode = .read_write });
    defer file.close();

    const fd = file.handle;
    const result = try i2c.I2cReadReg(fd, 0x0241);

    std.debug.print("Read data: {x}, {x}\n", .{ result[0], result[1] });
}
