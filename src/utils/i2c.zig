const std = @import("std");
const linux = std.os.linux;

const DEV_ADDR = 0x24;
const I2C_M_RD = 0x0001;
const I2C_RDWR = 0x0707;

const I2c_msg = extern struct {
    addr: u16,
    flags: u16,
    len: u16,
    buf: [*]u8,
};

const I2c_rdwr_ioctl_data = extern struct {
    msgs: [*]I2c_msg,
    nmsgs: u32,
};

pub fn i2cWriteReg(fd: std.posix.fd_t, reg_addr: u16, data: [2]u8) !void {
    if (reg_addr > 0xFF) {
        return i2cWriteRegLarge(fd, reg_addr, data);
    } else {
        return i2cWriteRegSmall(fd, @intCast(reg_addr), data);
    }
}

pub fn I2cReadReg(fd: std.posix.fd_t, reg_addr: u16) ![2]u8 {
    if (reg_addr > 0xFF) {
        return I2cReadRegLarge(fd, reg_addr);
    } else {
        return I2cReadRegSmall(fd, @intCast(reg_addr));
    }
}

fn i2cWriteRegLarge(fd: std.posix.fd_t, reg_addr: u16, data: [2]u8) !void {
    var buf = [_]u8{ @intCast((reg_addr >> 8) | 0b10000000), @intCast(reg_addr & 0xFF), data[0], data[1] };

    var msg = I2c_msg{
        .addr = DEV_ADDR,
        .flags = 0,
        .len = @intCast(buf.len),
        .buf = &buf,
    };

    var ioctl_data = I2c_rdwr_ioctl_data{
        .msgs = &msg,
        .nmsgs = 1,
    };

    const rc = linux.ioctl(fd, I2C_RDWR, @intFromPtr(&ioctl_data));
    if (rc < 0) {
        return std.os.linux.errno(rc);
    }
}

fn i2cWriteRegSmall(fd: std.posix.fd_t, reg_addr: u8, data: [2]u8) !void {
    var buf = [_]u8{ reg_addr, data[0], data[1] };

    var msg = I2c_msg{
        .addr = DEV_ADDR,
        .flags = 0,
        .len = @intCast(buf.len),
        .buf = &buf,
    };

    var ioctl_data = I2c_rdwr_ioctl_data{
        .msgs = &msg,
        .nmsgs = 1,
    };

    const rc = linux.ioctl(fd, I2C_RDWR, @intFromPtr(&ioctl_data));
    if (rc < 0) {
        return std.os.linux.errno(rc);
    }
}

fn I2cReadRegLarge(fd: std.posix.fd_t, reg_addr: u16) ![2]u8 {
    var addr_buf = [_]u8{ @intCast((reg_addr >> 8) | 0b10000000), @intCast(reg_addr & 0xFF) };
    var data_buf = [_]u8{ 0, 0 };

    var msgs = [_]I2c_msg{ .{
        .addr = DEV_ADDR,
        .flags = 0,
        .len = 2,
        .buf = &addr_buf,
    }, .{
        .addr = DEV_ADDR,
        .flags = I2C_M_RD,
        .len = 2,
        .buf = &data_buf,
    } };

    var ioctl_data = I2c_rdwr_ioctl_data{
        .msgs = &msgs,
        .nmsgs = @intCast(msgs.len),
    };

    const rc = linux.ioctl(fd, I2C_RDWR, @intFromPtr(&ioctl_data));
    if (rc < 0) {
        return std.os.linux.errno(rc);
    }
    return data_buf;
}
fn I2cReadRegSmall(fd: std.posix.fd_t, reg_addr: u8) ![2]u8 {
    var addr_buf = [_]u8{reg_addr};
    var data_buf = [_]u8{ 0, 0 };

    var msgs = [_]I2c_msg{ .{
        .addr = DEV_ADDR,
        .flags = 0,
        .len = 1,
        .buf = &addr_buf,
    }, .{
        .addr = DEV_ADDR,
        .flags = I2C_M_RD,
        .len = 2,
        .buf = &data_buf,
    } };

    var ioctl_data = I2c_rdwr_ioctl_data{
        .msgs = &msgs,
        .nmsgs = @intCast(msgs.len),
    };

    const rc = linux.ioctl(fd, I2C_RDWR, @intFromPtr(&ioctl_data));
    if (rc < 0) {
        return std.os.linux.errno(rc);
    }
    return data_buf;
}
