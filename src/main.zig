//! # Exercises every public code path of the blocking (`void`) logger

const std = @import("std");

const Log = @import("logger").Log(void);

const ALL_LEVELS: []const []const u8 = &.{
    "DEBUG", "INFO", "WARN", "ERROR", "FATAL"
};

fn banner(title: []const u8) void {
    std.debug.print("\n<=== {s} ===>\n", .{title});
}

/// # File Size In Bytes
/// - Returns **null** when the file does not exist
fn fileSize(name: []const u8) ?u64 {
    const stat = std.fs.cwd().statFile(name) catch return null;
    return stat.size;
}

pub fn main(init: std.process.Init) !void {
    const heap = init.gpa;
    const io = init.io;

    // Console Output - pass `null` as the log file
    banner("1. Console output (file = null)");
    try Log.init(io, heap, null, ALL_LEVELS, false);

    Log.debug("{s}", .{"hello from debug"}, null, @src());

    Log.info("{s}", .{"hello from info"}, &.{
        .{.name = "john", .value = "doe"}
    }, @src());

    Log.warn("{s}", .{"hello from warn"}, &.{
        .{.name = "john", .value = "doe"},
        .{.name = "jane", .value = "doe"}
    }, @src());

    Log.err("{s}", .{"hello from err"}, null, @src());

    // An empty context slice renders as `{}`
    Log.info("{d} + {d} = {d}", .{2, 2, 4}, &.{}, @src());

    // Fatal is always blocking and only ever reaches the console
    Log.fatal("{s}", .{"hello from fatal"}, null, @src());

    Log.deinit();
    Log.deinit(); // Double `deinit` is safe

    // 2) Invalid Level - `init` fails cleanly and can be retried right away
    banner("2. Invalid level rejected, then a clean retry");

    if (Log.init(io, heap, null, &.{ "DEBUG", "VERBOSE" }, false)) |_| {
        std.debug.print("unexpectedly accepted\n", .{});
        Log.deinit();
        return error.Unexpected;
    } else |e| {
        std.debug.print("rejected as expected - {s}\n", .{@errorName(e)});
    }

    // The failed attempt above must not leak its `DEBUG` flag into this
    // retry - all four entries below must therefore stay invisible
    try Log.init(io, heap, null, &.{ "WARN", "ERROR" }, false);

    Log.debug("invisible - DEBUG is inactive", .{}, null, @src());
    Log.info("invisible - INFO is inactive", .{}, null, @src());
    Log.warn("visible", .{}, null, @src());
    Log.err("visible", .{}, null, @src());
    Log.fatal("invisible - FATAL is inactive", .{}, null, @src());

    Log.deinit();

    // 3) File Output - appends across runs (`truncate = false`)
    banner("3. File output (demo.log)");
    try Log.init(io, heap, "demo.log", ALL_LEVELS, false);

    Log.debug("{s}", .{"file hello from debug"}, null, @src());

    Log.info("{s}", .{"file hello from info"}, &.{
        .{.name = "john", .value = "doe"}
    }, @src());

    Log.warn("{s}", .{"file hello from warn"}, &.{
        .{.name = "john", .value = "doe"},
        .{.name = "jane", .value = "doe"}
    }, @src());

    Log.err("{s}", .{"file hello from err"}, null, @src());

    // Fatal skips the file entirely - it only ever reaches `stdout`
    Log.fatal("{s}", .{"fatal - stdout only, never in demo.log"}, null, @src());

    Log.deinit();

    // 4) Unit-Test Mode - the file is created but stays empty
    banner("4. Test mode (on_test = true)");
    try Log.init(io, heap, "demo.log", ALL_LEVELS, true);

    Log.info("suppressed - no output is allowed in unit tests", .{}, null, @src());

    Log.deinit();

    if (std.Io.Dir.cwd().statFile(io, "demo.log", .{})) |stat| {
        std.debug.print(
            "demo.log exists and holds {d} bytes\n", .{stat.size}
        );
    } else |_| {}
}
