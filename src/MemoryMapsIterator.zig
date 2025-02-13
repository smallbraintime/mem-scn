const std = @import("std");
const common = @import("common.zig");
const pid_t = common.pid_t;
const MemScnError = common.MemScnError;

pub const MemoryRegion = struct {
    start: usize,
    end: usize,
    permission: Permission,
};

pub const Permission = enum(u8) {
    read,
    write,
    none,
};

const MemoryMapsIterator = @This();

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
