pub const pid_t = @import("std").posix.pid_t;

pub const MemScnError = error{
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
