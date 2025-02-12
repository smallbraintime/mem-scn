const std = @import("std");
const pid_t = std.posix.pid_t;

const MemScnError = error{
    InvalidCommand,
    InvalidPid,
    InvalidAddress,
    InvalidData,
    AddressNotFound,
    MemoryWriteFailure,
    FileNotFound,
    AccessDenied,
    Other,
};

const MemMapsIterator = struct {
    file: std.fs.File,
    reader: std.io.BufferedReader(4096, std.fs.File.Reader),
    line: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, pid: pid_t) MemScnError!MemMapsIterator {
        const path_pattern = "/proc/{d}/maps";
        var buf: [std.fmt.count(path_pattern, .{std.math.minInt(pid_t)})]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, path_pattern, .{pid}) catch return MemScnError.Other;

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return MemScnError.FileNotFound,
            error.AccessDenied => return MemScnError.AccessDenied,
            else => return MemScnError.Other,
        };

        const buffered_reader = std.io.bufferedReader(file.reader());

        return .{
            .file = file,
            .reader = buffered_reader,
            .line = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *MemMapsIterator) void {
        self.file.close();
        self.line.deinit();
    }

    pub fn next(self: *MemMapsIterator) MemScnError!?MemoryRegion {
        self.reader.reader().streamUntilDelimiter(self.line.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return MemScnError.Other,
        };

        const region = try parseMap(self.line.items);

        self.line.clearRetainingCapacity();

        return region;
    }
};

pub fn readMemory(allocator: std.mem.Allocator, pid: pid_t, data: []const u8, results: *std.ArrayList(usize)) MemScnError!bool {
    var iter = try MemMapsIterator.init(allocator, pid);
    defer iter.deinit();

    var any_found: bool = false;

    while (try iter.next()) |region| {
        if (region.permission != .none) {
            var buf: [4096]u8 = undefined;
            var current: usize = region.start;

            while (current < region.end) {
                var chunk_size = buf.len;
                if (current + chunk_size > region.end) {
                    chunk_size = region.end - current;
                }

                const bytes_read = processMemory(pid, current, &buf, chunk_size);
                if (std.os.linux.E.init(bytes_read) != .SUCCESS) break;

                if (bytes_read > 0) {
                    for (0..bytes_read - data.len) |i| {
                        if (std.mem.eql(u8, buf[i .. i + data.len], data)) {
                            any_found = true;
                            results.append(current + i) catch return MemScnError.Other;
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
    }

    return any_found;
}

fn processMemory(pid: pid_t, addr: usize, buf: [*]u8, len: usize) usize {
    var local: [1]std.posix.iovec = .{.{
        .base = buf,
        .len = len,
    }};

    const remote: [1]std.posix.iovec_const = .{.{
        .base = @ptrFromInt(addr),
        .len = len,
    }};

    return std.os.linux.process_vm_readv(pid, &local, &remote, 0);
}

pub fn writeMemory(allocator: std.mem.Allocator, pid: pid_t, addr: usize, data: [:0]const u8) MemScnError!void {
    var iter = try MemMapsIterator.init(allocator, pid);
    defer iter.deinit();

    var mregion: ?MemoryRegion = null;
    while (try iter.next()) |region| {
        if (region.start <= addr and region.end > addr) {
            mregion = region;
            break;
        }
    }

    const region = mregion orelse return MemScnError.AddressNotFound;

    if (addr + data.len > region.end) return MemScnError.MemoryWriteFailure;

    const mask: usize = 0xFFF;
    const address = addr & ~(mask);
    const slice = @as([*]align(std.mem.page_size) u8, @ptrFromInt(address))[0..std.mem.page_size];
    if (region.permission != .write) {
        std.posix.mprotect(slice, std.posix.PROT.WRITE) catch return MemScnError.AccessDenied;
    }

    defer {
        if (region.permission != .write) std.posix.mprotect(slice, std.posix.PROT.WRITE) catch unreachable;
    }

    const local: [1]std.posix.iovec_const = .{.{
        .base = @ptrCast(data.ptr),
        .len = data.len,
    }};

    const remote: [1]std.posix.iovec_const = .{.{
        .base = @ptrFromInt(addr),
        .len = data.len,
    }};

    const result = std.os.linux.process_vm_writev(pid, &local, &remote, 0);
    if (std.os.linux.E.init(result) != .SUCCESS) return MemScnError.MemoryWriteFailure;
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

fn parseMap(line: []const u8) MemScnError!MemoryRegion {
    var it = std.mem.splitScalar(u8, line, ' ');

    var it2 = std.mem.splitScalar(u8, it.next().?, '-');
    const start: usize = std.fmt.parseInt(usize, it2.next().?, 16) catch return MemScnError.Other;
    const end: usize = std.fmt.parseInt(usize, it2.next().?, 16) catch return MemScnError.Other;

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

const Command = union(enum) {
    read_mem: struct {
        pid: pid_t,
        data: [:0]const u8,
    },
    write_mem: struct {
        pid: pid_t,
        addr: usize,
        data: [:0]const u8,
    },
    help: void,
};

fn parseArgs() MemScnError!Command {
    var args = std.process.args();
    _ = args.skip();

    if (args.next()) |command| {
        if (std.mem.eql(u8, command, "read")) {
            var pid: pid_t = undefined;
            if (args.next()) |pid_str| {
                pid = std.fmt.parseInt(pid_t, pid_str, 10) catch return MemScnError.InvalidPid;
            } else {
                return MemScnError.InvalidPid;
            }

            var data: [:0]const u8 = undefined;
            if (args.next()) |d| {
                data = d;
            } else {
                return MemScnError.InvalidData;
            }

            return .{ .read_mem = .{ .pid = pid, .data = data } };
        }

        if (std.mem.eql(u8, command, "write")) {
            var pid: pid_t = undefined;
            if (args.next()) |pid_str| {
                pid = std.fmt.parseInt(pid_t, pid_str, 10) catch return MemScnError.InvalidPid;
            } else {
                return MemScnError.InvalidPid;
            }

            var addr: usize = undefined;
            if (args.next()) |addr_str| {
                addr = std.fmt.parseInt(usize, addr_str, 10) catch return MemScnError.InvalidAddress;
            } else {
                return MemScnError.InvalidAddress;
            }

            var data: [:0]const u8 = undefined;
            if (args.next()) |value| {
                data = value;
            } else {
                return MemScnError.InvalidData;
            }

            return .{ .write_mem = .{ .pid = pid, .addr = addr, .data = data } };
        }

        if (std.mem.eql(u8, command, "help")) return .help;
    }

    return MemScnError.InvalidCommand;
}

const HELP =
    \\Usage: mem-scn <command> [arguments]
    \\Commands:
    \\  help                                Display this help message
    \\  read <pid> <value>                  Find memory with given value from process and assigns id to each one (if we won't provide <value> then it will read all addresses)
    \\  write <pid> <id_or_addr> <value>    Write value to address in process (you can provide exact memory address or id provided by 'read' command)
    \\
;

const INVALID = "Invalid command! Try 'mem-scn help' to list available commands.\n";

fn run(allocator: std.mem.Allocator) MemScnError!void {
    const command = try parseArgs();

    switch (command) {
        .read_mem => |*args| {
            var addrs = std.ArrayList(usize).init(allocator);
            defer addrs.deinit();

            if (!try readMemory(allocator, args.pid, args.data, &addrs)) {
                std.debug.print("Memory with given value not found.\n", .{});
                return;
            }

            std.debug.print("Value '{s}' found at:\n", .{args.data});

            for (1.., addrs.items) |i, addr| {
                std.debug.print("{}. {}\n", .{ i, addr });
            }
        },
        .write_mem => |*args| {
            try writeMemory(allocator, args.pid, args.addr, args.data);
        },
        .help => std.debug.print(HELP, .{}),
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("memory leak occured");

    run(gpa.allocator()) catch |err| {
        switch (err) {
            MemScnError.InvalidCommand => std.debug.print(INVALID, .{}),
            MemScnError.InvalidPid => std.debug.print("Invalid Pid.\n", .{}),
            MemScnError.InvalidAddress => std.debug.print("Invalid Memory Address.\n", .{}),
            MemScnError.InvalidData => std.debug.print("Invalid Data.\n", .{}),
            MemScnError.AddressNotFound => std.debug.print("Address Not Found.\n", .{}),
            MemScnError.MemoryWriteFailure => std.debug.print("Memory Write Failure.\n", .{}),
            MemScnError.FileNotFound => std.debug.print("Pid Not Found.\n", .{}),
            MemScnError.AccessDenied => std.debug.print("Access Denied. Try run as a root.\n", .{}),
            MemScnError.Other => std.debug.print("Something Goes Wrong.\n", .{}),
        }
    };
}
