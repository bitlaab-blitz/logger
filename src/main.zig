const std = @import("std");

const Log = @import("logger").Log(void);

pub fn main() !void {
    std.debug.print("Hello, World!\n", .{});

    // Write your code here...

    var gpa_mem = std.heap.DebugAllocator(.{}).init;
    defer std.debug.assert(gpa_mem.deinit() == .ok);
    const heap = gpa_mem.allocator();

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
}
