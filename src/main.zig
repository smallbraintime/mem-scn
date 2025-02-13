const std = @import("std");
const pid_t = std.posix.pid_t;

const MemScnError = error{
    InvalidCommand,
    InvalidPid,
    InvalidAddress,
    InvalidValue,
    InvalidType,
    TooFewArgs,
    AddressNotFound,
    MemoryWriteFailure,
    FileNotFound,
    AccessDenied,
    Other,
};

const MemoryMapsIterator = struct {
    file: std.fs.File,
    reader: std.io.BufferedReader(4096, std.fs.File.Reader),
    line: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, pid: pid_t) MemScnError!MemoryMapsIterator {
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

    pub fn deinit(self: *MemoryMapsIterator) void {
        self.file.close();
        self.line.deinit();
    }

    pub fn next(self: *MemoryMapsIterator) MemScnError!?MemoryRegion {
        self.reader.reader().streamUntilDelimiter(self.line.writer(), '\n', null) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return MemScnError.Other,
        };

        const region = try parseMap(self.line.items);

        self.line.clearRetainingCapacity();

        return region;
    }
};

pub fn readMemory(allocator: std.mem.Allocator, pid: pid_t, value: []const u8, results: *std.ArrayList(usize)) MemScnError!bool {
    var iter = try MemoryMapsIterator.init(allocator, pid);
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
                    for (0..bytes_read - value.len) |i| {
                        if (std.mem.eql(u8, buf[i .. i + value.len], value)) {
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

pub fn writeMemory(allocator: std.mem.Allocator, pid: pid_t, addr: usize, value: [:0]const u8) MemScnError!void {
    var iter = try MemoryMapsIterator.init(allocator, pid);
    defer iter.deinit();

    var mregion: ?MemoryRegion = null;
    while (try iter.next()) |region| {
        if (region.start <= addr and region.end > addr) {
            mregion = region;
            break;
        }
    }

    const region = mregion orelse return MemScnError.AddressNotFound;

    if (addr + value.len > region.end) return MemScnError.MemoryWriteFailure;

    const local: [1]std.posix.iovec_const = .{.{
        .base = @ptrCast(value.ptr),
        .len = value.len,
    }};

    const remote: [1]std.posix.iovec_const = .{.{
        .base = @ptrFromInt(addr),
        .len = value.len,
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
        value: Value,
    },
    write_mem: struct {
        pid: pid_t,
        addr: usize,
        value: Value,
    },
    help: void,
};

const Value = union(enum) {
    str: [:0]const u8,
    num: NumByteArray,
};

const NumByteArray = struct {
    value: [@sizeOf(f64):0]u8,
    size: usize,

    pub fn toSlice(self: *const NumByteArray) [:0]const u8 {
        return @ptrCast(self.value[0..self.size]);
    }
};

fn parseArgs() MemScnError!Command {
    var args = std.process.args();
    _ = args.skip();

    if (args.next()) |command| {
        if (std.mem.eql(u8, command, "read")) {
            var cmd_args: [3][:0]const u8 = undefined;

            for (&cmd_args) |*arg| {
                arg.* = args.next() orelse return MemScnError.TooFewArgs;
            }

            const pid = std.fmt.parseInt(pid_t, cmd_args[0], 10) catch return MemScnError.InvalidPid;

            const type_str = cmd_args[1];
            var value: Value = undefined;
            if (std.mem.eql(u8, type_str, "str")) {
                value = .{ .str = cmd_args[2] };
            } else {
                value = .{ .num = try strNumToByteArr(type_str, cmd_args[2]) };
            }

            return .{ .read_mem = .{ .pid = pid, .value = value } };
        }

        if (std.mem.eql(u8, command, "write")) {
            var cmd_args: [4][:0]const u8 = undefined;

            for (&cmd_args) |*arg| {
                arg.* = args.next() orelse return MemScnError.TooFewArgs;
            }

            const pid = std.fmt.parseInt(pid_t, cmd_args[0], 10) catch return MemScnError.InvalidPid;

            const addr = std.fmt.parseInt(usize, cmd_args[1], 16) catch return MemScnError.InvalidAddress;

            const type_str = cmd_args[2];
            var value: Value = undefined;
            if (std.mem.eql(u8, type_str, "str")) {
                value = .{ .str = cmd_args[3] };
            } else {
                value = .{ .num = try strNumToByteArr(type_str, cmd_args[3]) };
            }

            return .{ .write_mem = .{ .pid = pid, .addr = addr, .value = value } };
        }

        if (std.mem.eql(u8, command, "help")) return .help;
    }

    return MemScnError.InvalidCommand;
}

const HELP =
    \\Usage: mem-scn <command> [arguments]
    \\Commands:
    \\  help                                Display this help message.
    \\  read <pid> <type> <value>           Find memory with a given value and type from process.
    \\  write <pid> <addr> <type> <value>   Write value with a given type to address in process.
    \\
;

fn run(allocator: std.mem.Allocator) MemScnError!void {
    const command = try parseArgs();

    switch (command) {
        .read_mem => |*args| {
            var addrs = std.ArrayList(usize).init(allocator);
            defer addrs.deinit();

            var value: [:0]const u8 = undefined;
            switch (args.value) {
                .str => |v| value = v,
                .num => |*v| value = v.toSlice(),
            }

            if (!try readMemory(allocator, args.pid, value, &addrs)) {
                std.debug.print("Memory with a given value and type not found.\n", .{});
                return;
            }

            std.debug.print("Value found at:\n", .{});

            for (1.., addrs.items) |i, addr| {
                std.debug.print("{}. {x}\n", .{ i, addr });
            }
        },
        .write_mem => |*args| {
            var value: [:0]const u8 = undefined;
            switch (args.value) {
                .str => |v| value = v,
                .num => |*v| value = v.toSlice(),
            }

            try writeMemory(allocator, args.pid, args.addr, value);
            std.debug.print("Value has been written successfully.\n", .{});
        },
        .help => std.debug.print(HELP, .{}),
    }
}

fn strNumToByteArr(type_str: [:0]const u8, value: [:0]const u8) MemScnError!NumByteArray {
    if (std.mem.eql(u8, "u8", type_str)) {
        const n = std.fmt.parseInt(u8, value, 10) catch return MemScnError.InvalidValue;
        const bytes = std.mem.toBytes(n);
        var byte_arr = NumByteArray{ .value = undefined, .size = @sizeOf(u8) };
        std.mem.copyForwards(u8, &byte_arr.value, &bytes);
        return byte_arr;
    }
    if (std.mem.eql(u8, "i8", type_str)) {
        const n = std.fmt.parseInt(i8, value, 10) catch return MemScnError.InvalidValue;
        const bytes = std.mem.toBytes(n);
        var byte_arr = NumByteArray{ .value = undefined, .size = @sizeOf(i8) };
        std.mem.copyForwards(u8, &byte_arr.value, &bytes);
        return byte_arr;
    }
    if (std.mem.eql(u8, "u16", type_str)) {
        const n = std.fmt.parseInt(u16, value, 10) catch return MemScnError.InvalidValue;
        const bytes = std.mem.toBytes(n);
        var byte_arr = NumByteArray{ .value = undefined, .size = @sizeOf(u16) };
        std.mem.copyForwards(u8, &byte_arr.value, &bytes);
        return byte_arr;
    }
    if (std.mem.eql(u8, "i16", type_str)) {
        const n = std.fmt.parseInt(i16, value, 10) catch return MemScnError.InvalidValue;
        const bytes = std.mem.toBytes(n);
        var byte_arr = NumByteArray{ .value = undefined, .size = @sizeOf(i16) };
        std.mem.copyForwards(u8, &byte_arr.value, &bytes);
        return byte_arr;
    }
    if (std.mem.eql(u8, "u32", type_str)) {
        const n = std.fmt.parseInt(u32, value, 10) catch return MemScnError.InvalidValue;
        const bytes = std.mem.toBytes(n);
        var byte_arr = NumByteArray{ .value = undefined, .size = @sizeOf(u32) };
        std.mem.copyForwards(u8, &byte_arr.value, &bytes);
        return byte_arr;
    }
    if (std.mem.eql(u8, "i32", type_str)) {
        const n = std.fmt.parseInt(i32, value, 10) catch return MemScnError.InvalidValue;
        const bytes = std.mem.toBytes(n);
        var byte_arr = NumByteArray{ .value = undefined, .size = @sizeOf(i32) };
        std.mem.copyForwards(u8, &byte_arr.value, &bytes);
        return byte_arr;
    }
    if (std.mem.eql(u8, "u64", type_str)) {
        const n = std.fmt.parseInt(u64, value, 10) catch return MemScnError.InvalidValue;
        const bytes = std.mem.toBytes(n);
        var byte_arr = NumByteArray{ .value = undefined, .size = @sizeOf(u64) };
        std.mem.copyForwards(u8, &byte_arr.value, &bytes);
        return byte_arr;
    }
    if (std.mem.eql(u8, "i64", type_str)) {
        const n = std.fmt.parseInt(i64, value, 10) catch return MemScnError.InvalidValue;
        const bytes = std.mem.toBytes(n);
        var byte_arr = NumByteArray{ .value = undefined, .size = @sizeOf(i64) };
        std.mem.copyForwards(u8, &byte_arr.value, &bytes);
        return byte_arr;
    }
    if (std.mem.eql(u8, "f32", type_str)) {
        const n = std.fmt.parseFloat(f32, value) catch return MemScnError.InvalidValue;
        const bytes = std.mem.toBytes(n);
        var byte_arr = NumByteArray{ .value = undefined, .size = @sizeOf(f32) };
        std.mem.copyForwards(u8, &byte_arr.value, &bytes);
        return byte_arr;
    }
    if (std.mem.eql(u8, "f64", type_str)) {
        const n = std.fmt.parseFloat(f64, value) catch return MemScnError.InvalidValue;
        const bytes = std.mem.toBytes(n);
        var byte_arr = NumByteArray{ .value = undefined, .size = @sizeOf(f64) };
        std.mem.copyForwards(u8, &byte_arr.value, &bytes);
        return byte_arr;
    }
    return MemScnError.InvalidType;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("memory leak occured");

    run(gpa.allocator()) catch |err| {
        switch (err) {
            MemScnError.InvalidCommand => std.debug.print("Invalid command. Try 'mem-scn help' to list available commands.\n", .{}),
            MemScnError.InvalidPid => std.debug.print("Invalid Pid.\n", .{}),
            MemScnError.InvalidAddress => std.debug.print("Invalid Memory Address.\n", .{}),
            MemScnError.InvalidValue => std.debug.print("Invalid Value.\n", .{}),
            MemScnError.InvalidType => std.debug.print("Invalid Type.\n", .{}),
            MemScnError.TooFewArgs => std.debug.print("Too few arguments. Try 'mem-scn help' to see available commands.\n", .{}),
            MemScnError.AddressNotFound => std.debug.print("Address Not Found.\n", .{}),
            MemScnError.MemoryWriteFailure => std.debug.print("Memory Write Failure.\n", .{}),
            MemScnError.FileNotFound => std.debug.print("Pid Not Found.\n", .{}),
            MemScnError.AccessDenied => std.debug.print("Access Denied. Try run as a root.\n", .{}),
            MemScnError.Other => std.debug.print("Something Goes Wrong.\n", .{}),
        }
    };
}
