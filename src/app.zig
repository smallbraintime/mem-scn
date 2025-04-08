const std = @import("std");
const common = @import("common.zig");
const pid_t = common.pid_t;
const MemScnError = common.MemScnError;
const mem = @import("mem.zig");
const readMemory = mem.readMemory;
const writeMemory = mem.writeMemory;

pub fn run(allocator: std.mem.Allocator) MemScnError!void {
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
                std.debug.print("Memory with the given value and type was not found.\n", .{});
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
        .help => {
            const HELP =
                \\Usage: mem-scn <command> [arguments]
                \\Commands:
                \\  help                                Display this help message.
                \\  version                             Display the version of the app.
                \\  read <pid> <type> <value>           Find memory with a given value and type from process.
                \\  write <pid> <addr> <type> <value>   Write value with a given type to address in process.
                \\
                \\Types: u8, i8, u16, i16, u32, i32, u64, i64, str
                \\
            ;
            std.debug.print(HELP, .{});
        },
        .version => std.debug.print("mem-scn 0.1.0\n", .{}),
    }
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
    version: void,
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
        if (std.mem.eql(u8, command, "version")) return .version;
    }

    return MemScnError.InvalidCommand;
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

test "strNumToByteArr" {
    try std.testing.expectEqual((try strNumToByteArr("u64", "1234")).value, .{ 0xD2, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try std.testing.expectError(MemScnError.InvalidValue, strNumToByteArr("u8", "1234"));
}
