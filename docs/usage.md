# How to use

First, import Logger on your Zig source file.

```zig
const Log = @import("logger").Log(void); // Blocking I/O
```

Now, add the following code into your main function.

```zig
var gpa_mem = std.heap.DebugAllocator(.{}).init;
defer std.debug.assert(gpa_mem.deinit() == .ok);
const heap = gpa_mem.allocator();
```

## Log.init()

```zig
try Log.init(io, heap, file, levels, on_test);
```

- `io` - The `Io` interface (e.g., `init.io` from `main`).
- `heap` - The allocator used for internal formatting.
- `file` - Path of the given log file (relative or absolute).
    - Pass **null** to log to the terminal instead of a file.
- `levels` - One or more log level text (e.g., `DEBUG`).
    - Omitting a level disables its log functions.
- `on_test` - Set to **true** inside unit tests to suppress all output.

**Remarks:** Call `init` only once per process; after `deinit()` it may be initialized again. Log level names are case-sensitive (`"DEBUG"`, `"INFO"`, `"WARN"`, `"ERROR"`, `"FATAL"`).

## Example: All Levels (blocking I/O)

Following snippet saves different level of logs into the given file. For terminal logging use **null** instead of the log file.

```zig
const levels = &.{"DEBUG", "INFO", "WARN", "ERROR", "FATAL"};

try Log.init(init.io, heap, "test.log", levels, false);
defer Log.deinit();


Log.debug("{s}", .{"hello from debug"}, null, @src());

Log.info(
    "{s}", .{"hello from info"}, &.{.{.name = "john", .value = "doe"}}, @src()
);

Log.warn(
    "{s}", .{"hello from warn"},
    &.{
        .{.name = "john", .value = "doe"},
        .{.name = "jane", .value = "doe"}
    },
    @src()
);

Log.err("{s}", .{"hello from err"}, null, @src());

Log.fatal("{s}", .{"hello from fatal"}, null, @src());
```

**Remarks:**

- `ctx` may be `null` or an empty slice `&.{}`.

## Example: Partial Levels

Only the given levels are active; their log functions execute, everything else is silently skipped.

```zig
try Log.init(init.io, heap, "app.log", &.{ "WARN", "ERROR" }, false);

Log.debug("invisible", .{}, null, @src()); // skipped
Log.info("invisible", .{}, null, @src());  // skipped
Log.warn("visible", .{}, null, @src());
Log.err("visible", .{}, null, @src());
```

**Remarks:** Invalid levels fail cleanly.

## Example: Unit-Test Mode

Passing `true` as the last argument of `Log.init()` creates the log file but suppresses every entry — legal inside unit tests.

```zig
try Log.init(init.io, heap, "test.log", levels, true); // on_test = true
Log.info("suppressed", .{}, null, @src()); // writes nothing
```

## Example: Fatal

`fatal` is always blocking and bypasses the configured output — it is written to `stdout` only, never to the log file. It is also subject to the `FATAL` level being enabled.

## Example: Async I/O

To enable asynchronous I/O (`io_uring` on Linux) you must provide the **AsyncIo** executor from [Saturn](https://bitlaab.com/api-doc?pkg=saturn). On other platforms (or while the event loop is not running) the same calls fall back to blocking writes automatically.

```zig
const saturn = @import("saturn");

const Executor = saturn.TaskExecutor(1024);
const AsyncIo = saturn.AsyncIo(1024, Executor);

const Log = @import("logger").Log(AsyncIo);
```
