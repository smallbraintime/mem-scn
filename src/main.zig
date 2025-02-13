const std = @import("std");
const run = @import("app.zig").run;
const MemScnError = @import("common.zig").MemScnError;

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
