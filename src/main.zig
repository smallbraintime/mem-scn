const std = @import("std");

const MemScnError = error{
    InvalidPid,
    OpenFailure,
    PosixErr,
};

fn readMemory(pid: usize) !void {}

fn writeMemory() void {}

pub fn main() !void {}
