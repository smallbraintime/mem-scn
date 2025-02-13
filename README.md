# 🔧mem-scn
a simple linux memory scanner/modifier

### commands
```
Usage: mem-scn <command> [arguments]
Commands:
  help                                Display this help message.
  read <pid> <type> <value>           Find memory with a given value and type from process.
  write <pid> <addr> <type> <value>   Write value with a given type to address in process.
```

### build and run
```
zig build run
```
