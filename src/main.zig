const std = @import("std");

const MemScnError = error{ invalid_pid, posix_err, other };

fn readMemory(pid: usize, start: *anyopaque, size: usize, buf: *anyopaque) !void {
    _ = size;
    _ = buf;

    var file: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&file, "/proc/%ld/mem{}", .{pid});
    const fd = std.posix.open(file, 0, std.os.linux.SHUT.RDWR);
    if (fd == -1) return MemScnError.posix_err;

    if (std.posix.ptrace(std.os.linux.PTRACE.ATTACH, @intCast(pid), 0, 0) == -1) return MemScnError.posix_err;
    if (std.posix.waitpid(@intCast(pid), 0) == -1) return MemScnError.posix_err;

    const addr: std.posix.off_t = @intCast(start);
    var mem: [4096]u8 = undefined;
    try std.posix.pread(fd, &mem, addr);

    if (std.posix.ptrace(std.os.linux.PTRACE.DETACH, @intCast(pid), 0, 0) == -1) return MemScnError.posix_err;
    std.posix.close(fd);
}

fn writeMemory(pid: usize, ptr: *anyopaque, data: *anyopaque) void {
    var file: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&file, "/proc/%ld/mem{}", .{pid});
    const fd = std.posix.open(file, 0, std.os.linux.SHUT.RDWR);
    if (fd == -1) return MemScnError.posix_err;

    if (std.posix.ptrace(std.os.linux.PTRACE.ATTACH, @intCast(pid), 0, 0) == -1) return MemScnError.posix_err;
    if (std.posix.waitpid(@intCast(pid), 0) == -1) return MemScnError.posix_err;

    const addr: std.posix.off_t = @intCast(ptr);
    if (std.posix.pwrite(fd, data, addr) == -1) return MemScnError.posix_err;

    if (std.posix.ptrace(std.os.linux.PTRACE.DETACH, @intCast(pid), 0, 0) == -1) return MemScnError.posix_err;
    std.posix.close(fd);
}

fn findPattern() void {}

const Command = union(enum) {
    read_mem: struct {
        pid: usize,
        data: ?[]const u8 = null,
    },
    write_mem: struct {
        pid: usize,
        addr: usize,
        data: []const u8,
    },
    help: void,
    invalid: void,
};

fn parseArgs() !Command {
    var args = std.process.args();
    _ = args.skip();

    if (args.next()) |command| {
        if (std.mem.eql(u8, command, "read")) {
            var pid: usize = undefined;
            if (args.next()) |pid_str| {
                pid = std.fmt.parseInt(usize, pid_str, 10) catch return MemScnError.other;
            } else {
                return .invalid;
            }

            const data = args.next();

            return .{ .read_mem = .{ .pid = pid, .data = data } };
        }

        if (std.mem.eql(u8, command, "write")) {
            var pid: usize = undefined;
            if (args.next()) |pid_str| {
                pid = std.fmt.parseInt(usize, pid_str, 10) catch return MemScnError.other;
            } else {
                return .invalid;
            }

            var addr: usize = undefined;
            if (args.next()) |addr_str| {
                addr = std.fmt.parseInt(usize, addr_str, 10) catch return MemScnError.other;
            } else {
                return .invalid;
            }

            var data: []const u8 = undefined;
            if (args.next()) |value| {
                data = value;
            } else {
                return .invalid;
            }

            return .{ .write_mem = .{ .pid = pid, .addr = addr, .data = data } };
        }

        if (std.mem.eql(u8, command, "help")) return .help;
    }

    return .invalid;
}

const HELP =
    \\Usage: mem-scn <command> [arguments]
    \\Commands:
    \\  help                                Display this help message
    \\  read <pid> <value>                  Find memory with given value from process and assigns id to each one (if we won't provide <value> then it will read all addresses)
    \\  write <pid> <id_or_addr> <value>    Write value to address in process (you can provide exact memory address or id provided by 'read' command)
    \\
;

const INVALID = "Invalid command! Try 'mem-scn help' to list available commands\n";

pub fn main() !void {
    const command = try parseArgs();

    switch (command) {
        .read_mem => |*args| {
            _ = args;
        },
        .write_mem => |*args| {
            _ = args;
        },
        .help => std.debug.print(HELP, .{}),
        .invalid => std.debug.print(INVALID, .{}),
    }
}
