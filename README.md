# 🔧mem-scn

a simple linux memory scanner/modifier

### commands

```
Usage: mem-scn <command> [arguments]
Commands:
  help                                Display this help message.
  version                             Display the version of the app.
  read <pid> <type> <value>           Find memory with a given value and type from process.
  write <pid> <addr> <type> <value>   Write value with a given type to address in process.

Types: u8, i8, u16, i16, u32, i32, u64, i64, str
```

### build and run example

```
sudo zig build run -- read 1 str some
```

### run tests

```
sudo zig build test
```
