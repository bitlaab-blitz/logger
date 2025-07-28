# How to use

First, import Logger on your Zig source file.

```zig
const Log = @import("logger").Log(void);
```

Now, add the following code into your main function.

```zig
var gpa_mem = std.heap.DebugAllocator(.{}).init;
defer std.debug.assert(gpa_mem.deinit() == .ok);
const heap = gpa_mem.allocator();
```

## Example: Blocking I/O

Following snippet saves different level of logs into the given file. For terminal logging use **null** instead of the log file.

```zig
const levels = &.{"DEBUG", "INFO", "WARN", "ERROR", "FATAL"};

try Log.init(heap, "test.log", levels, false);
defer Log.deinit();


Log.debug("{s}", .{"hello from debug"}, null, @src());

Log.info("{s}", .{"hello from info"}, &.{
    .{.name = "john", .value = "doe"}
}, @src());

Log.warn("{s}", .{"hello from warn"}, &.{
    .{.name = "john", .value = "doe"},
    .{.name = "jane", .value = "doe"}
}, @src());

Log.err("{s}", .{"hello from err"}, null, @src());

Log.fatal("{s}", .{"hello from fatal"}, null, @src());
```

**Remarks:** If you omit a log level in Log.init(), its corresponding log functions won’t execute — enabling dynamic logging control in production.

## Example: Async I/O

To enable asynchronous I/O you must provide the **AsyncIo** executor from [Saturn](https://bitlaabsaturn.web.app/). Rest of the code will be the same.

```zig

const saturn = @import("saturn");
pub const AsyncIo = saturn.AsyncIo(1024, void);

const Log = @import("logger").Log(AsyncIo);
```
