const std = @import("std");
const common = @import("common.zig");
const pid_t = common.pid_t;
const MemScnError = common.MemScnError;
const MemMappingsIterator = @import("MemMappingsIterator.zig");
const MemoryRegion = MemMappingsIterator.MemoryRegion;

pub fn readMemory(allocator: std.mem.Allocator, pid: pid_t, value: []const u8, results: *std.ArrayList(usize)) MemScnError!bool {
    var iter = try MemMappingsIterator.init(allocator, pid);
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

pub fn writeMemory(allocator: std.mem.Allocator, pid: pid_t, addr: usize, value: [:0]const u8) MemScnError!void {
    var iter = try MemMappingsIterator.init(allocator, pid);
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

test "read any mem" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("memory leak occured");

    var results = std.ArrayList(usize).init(gpa.allocator());
    defer results.deinit();

    try std.testing.expect(try readMemory(gpa.allocator(), 1, "a", &results));
    try std.testing.expectError(MemScnError.FileNotFound, readMemory(gpa.allocator(), 0, "a", &results));
}
