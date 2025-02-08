const std = @import("std");

const MemScnError = error{ invalid_pid, posix_err, other };

fn processMemory(pid: usize, addr: usize, buf: [*]u8, len: usize) usize {
    var local: [1]std.posix.iovec = .{.{
        .base = buf,
        .len = len,
    }};

    const remote: [1]std.posix.iovec_const = .{.{
        .base = @ptrFromInt(addr),
        .len = len,
    }};

    return std.os.linux.process_vm_readv(@intCast(pid), &local, &remote, 0);
}

fn iterMemory(pid: usize, allocator: std.mem.Allocator) !void {
    const pid_str = try std.fmt.allocPrint(allocator, "/proc/{}/maps", .{pid});
    defer allocator.free(pid_str);

    const file = try std.fs.openFileAbsolute(pid_str, .{});
    defer file.close();

    var buffered_reader = std.io.bufferedReader(file.reader());
    var reader = buffered_reader.reader();

    var line = std.ArrayList(u8).init(allocator);
    defer line.deinit();

    while (true) {
        reader.streamUntilDelimiter(line.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        // std.debug.print("{s}\n", .{line.items});

        const region = try parseMap(line.items);
        // std.debug.print("start: {}, end: {}, permission: {}\n", .{ region.start, region.end, region.permission });

        if (region.permission == .read) {
            var buf: [4096]u8 = undefined;
            var current: usize = region.start;

            while (current < region.end) {
                var chunk_size = buf.len;
                if (current + chunk_size > region.end) {
                    chunk_size = region.end - current;
                }
                const bytes_read = processMemory(pid, region.start, &buf, chunk_size);
                if (bytes_read > buf.len) break;

                if (bytes_read > 0) {
                    // std.debug.print("{s}\n", .{&buf});
                    std.debug.print("bytes_read {}\n", .{bytes_read});
                    std.debug.print("chunk_size {}\n", .{chunk_size});
                    for (0..bytes_read - 4) |i| {
                        if (std.mem.eql(u8, buf[i .. i + 4], "play")) {
                            std.debug.print("value found at address: {}\n", .{region.start + i});
                        }
                    }
                }

                if (bytes_read > 0) {
                    current += bytes_read;
                } else {
                    current += chunk_size;
                }
            }
        }

        line.clearRetainingCapacity();
    }
}

const Permission = enum(u8) {
    read,
    write,
    none,
};

const MemoryRegion = struct {
    start: usize,
    end: usize,
    permission: Permission,
};

fn parseMap(line: []const u8) !MemoryRegion {
    var it = std.mem.splitScalar(u8, line, ' ');

    var it2 = std.mem.splitScalar(u8, it.next().?, '-');
    const start: usize = try std.fmt.parseInt(usize, it2.next().?, 16);
    const end: usize = try std.fmt.parseInt(usize, it2.next().?, 16);

    var permission: Permission = .none;
    var it3 = std.mem.splitScalar(u8, it.next().?, ' ');
    const perm = it3.next().?;
    for (perm) |c| {
        switch (c) {
            'r' => permission = .read,
            'w' => permission = .write,
            else => {},
        }
    }

    return .{
        .start = start,
        .end = end,
        .permission = permission,
    };
}

fn readMemory(pid: usize, data: ?[]const u8) void {
    _ = pid;
    _ = data;
}

fn writeMemory(pid: usize, addr: usize, data: []const u8) void {
    _ = pid;
    _ = addr;
    _ = data;
}

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("memory leak occured");

    const command = try parseArgs();

    switch (command) {
        .read_mem => |*args| {
            try iterMemory(args.pid, gpa.allocator());
        },
        .write_mem => |*args| {
            _ = args;
        },
        .help => std.debug.print(HELP, .{}),
        .invalid => std.debug.print(INVALID, .{}),
    }
}
