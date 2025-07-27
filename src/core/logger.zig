//! # Cross-platform Logger (Singleton)
//! - Provides a set of utilities for application level logging and debugging

const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;
const mem = std.mem;
const File = fs.File;
const linux = std.os.linux;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const SrcLoc = std.builtin.SourceLocation;

const utils = @import("./utils.zig");
const DateTime = @import("./datetime.zig");


const Error = error { InvalidLogLevel, FailedToOpenLogFile };

const DEBUG = 1 << 0;
const INFO = 1 << 1;
const WARN = 1 << 2;
const ERROR = 1 << 3;
const FATAL = 1 << 4;

const Str = []const u8;

const Log = struct { data: Str };
const Ctx = struct { name: Str, value: Str };

const OutputType = enum { Console, File };

const SingletonObject = struct {
    heap: ?Allocator,
    output: OutputType,
    level: u8,
    fd: ?i32,
    aio: type,
    on_test: bool
};

var so = SingletonObject {
    .heap = null,
    .output = OutputType.Console,
    .level = DEBUG | INFO | WARN | ERROR | FATAL,
    .fd = null,
    .aio = null,
    .on_test = false
};

const Self = @This();

/// # Initializes the Global Logger
/// - `aio` - AsyncIo singleton from Saturn, use **null** for blocking I/O
/// - `file` - Absolute path of the log file (e.g., `/home/joe/app/hydra.log`)
/// - `levels` - Any combination of - `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL`
/// - `on_test` - Determines if the logger is currently used in a unit test
pub fn init(
    heap: Allocator,
    comptime aio: type,
    file: ?Str,
    levels: []const Str,
    on_test: bool
) !void {
    if (Self.so.fd != null) @panic("Initialize Only Once Per Process!");

    const sop = Self.iso();

    sop.fd = 2;
    sop.aio = aio;
    sop.level = 0;
    sop.heap = heap;
    sop.on_test = on_test;

    if (file) |path| {
        const pathZ = try heap.dupeZ(u8, path);
        defer heap.free(pathZ);

        // the fd needs to be cross platform
        const res: isize = @bitCast(linux.openat(fs.cwd().fd, pathZ,
            linux.O {.ACCMODE = .WRONLY, .CREAT = true, .APPEND = true},
            0o644 // Octal literal for setting file permission
        ));

        if (res <= 0) {
            utils.syscallError(@truncate(res), @src());
            return Error.FailedToOpenLogFile;
        }

        sop.fd = @truncate(res);
        sop.output = OutputType.File;
    }

    for (levels) |level| {
        if (mem.eql(u8, level, "DEBUG")) sop.level |= DEBUG
        else if (mem.eql(u8, level, "INFO")) sop.level |= INFO
        else if (mem.eql(u8, level, "WARN")) sop.level |= WARN
        else if (mem.eql(u8, level, "ERROR")) sop.level |= ERROR
        else if (mem.eql(u8, level, "FATAL")) sop.level |= FATAL
        else return Error.InvalidLogLevel;
    }
}

/// # Destroys the Global Logger
pub fn deinit() void {
    const sop = Self.iso();
    if (sop.fd.? != 2) std.debug.assert(linux.close(sop.fd.?) == 0);
}

/// # Returns Internal Static Object
pub fn iso() *SingletonObject { return &Self.so; }

pub fn debug(comptime msg: Str, args: anytype, ctx: ?[]Ctx, src: SrcLoc) void {
    const sop = Self.iso();

    if (sop.level & DEBUG == DEBUG) {
        const heap = sop.heap.?;
        const data = fmt.allocPrint(heap, msg, args) catch {
            utils.oom(@src());
        };
        defer heap.free(data);

        const out = format("DEBUG", data, ctx, src) catch |e| {
            utils.unrecoverable(e, @src());
        };

        log(out, false) catch |e| utils.unrecoverable(e, @src());
    }
}

pub fn info(comptime msg: Str, args: anytype, ctx: ?[]Ctx, src: SrcLoc) void {
    const sop = Self.iso();

    if (sop.level & INFO == INFO) {
        const heap = sop.heap.?;
        const data = fmt.allocPrint(heap, msg, args) catch utils.oom(@src());
        defer heap.free(data);

        const out = format("INFO", data, ctx, src) catch |e| {
            utils.unrecoverable(e, @src());
            return;
        };

        log(out, false) catch |e| utils.unrecoverable(e, @src());
    }
}

pub fn warn(comptime msg: Str, args: anytype, ctx: ?[]Ctx, src: SrcLoc) void {
    const sop = Self.iso();

    if (sop.level & WARN == WARN) {
        const heap = sop.heap;
        const data = fmt.allocPrint(heap, msg, args) catch utils.oom(@src());
        defer heap.free(data);

        const out = format("WARN", data, ctx, src) catch |e| {
            utils.unrecoverable(e, @src());
        };

        log(out, false)  catch |e| utils.unrecoverable(e, @src());
    }
}

pub fn err(comptime msg: Str, args: anytype, ctx: ?[]Ctx, src: SrcLoc) void {
    const sop = Self.iso();

    if (sop.level & ERROR == ERROR) {
        const heap = sop.heap.?;
        const data = fmt.allocPrint(heap, msg, args) catch utils.oom(@src());
        defer heap.free(data);

        const out = format("ERROR", data, ctx, src) catch |e| {
            utils.unrecoverable(e, @src());
        };

        log(out, false)  catch |e| utils.unrecoverable(e, @src());
    }
}

pub fn fatal(comptime msg: Str, args: anytype, ctx: ?[]Ctx, src: SrcLoc) void {
    const sop = Self.iso();

    if (sop.level & FATAL == FATAL) {
        const heap = sop.heap.?;
        const data = fmt.allocPrint(heap, msg, args) catch utils.oom(@src());
        defer heap.free(data);

        const out = format("FATAL", data, ctx, src) catch |e| {
            utils.unrecoverable(e, @src());
        };

        log(out, true) catch |e| utils.unrecoverable(e, @src());
    }
}

fn log(data: Str, blocking: bool) !void {
    const sop = Self.iso();
    const heap = sop.heap.?;

    if (blocking or sop.aio.evlStatus() == .closed) {
        defer heap.free(data);

        if (sop.on_test) return;
        // Raw printing e.g., `StdOut` in unit tests is currently illegal
        // ↓ skips the following code when running on unit testing

        var std_out = std.io.getStdOut().writer();
        try std_out.print("{s}", .{data});
        return;
    }

    if (!sop.aio) {
        _ = try std.posix.write(sop.fd.?, data);
        // std.os.windows.WriteFile
        std.debug.print("logging with blocking mode\n", .{});
    }
    else {
        const log_data = try heap.create(Log);
        log_data.* = Log {.data = data};

        try sop.aio.write(free, @as(*anyopaque, log_data), .{
            .fd = sop.fd.?, .buff = data, .count = data.len, .offset = 0
        });
    }
}

fn free(cqe_res: i32, userdata: ?*anyopaque) void {
    std.debug.assert(cqe_res > 0);
    const heap = Self.iso().heap.?;

    const log_data: *Log = @ptrCast(@alignCast(userdata));
    heap.free(log_data.data);
    heap.destroy(log_data);
}

fn format(level: Str, msg: Str, data: ?[]Ctx, src: SrcLoc) !Str {
    const heap = Self.iso().heap.?;
    const datetime = DateTime.now().toLocal(.BST);

    return blk: {
        if (data) |ctx_data| {
            const out_str = try ctxFormat(ctx_data);
            defer heap.free(out_str);

            const fmt_str = "{s} [{s}] {s} at {d}:{d}\n{s}\n~{s}\n";
            break :blk try fmt.allocPrint(heap, fmt_str, .{
                datetime, level, src.file, src.line, src.column, out_str, msg
            });
        } else {
            const fmt_str = "{s} [{s}] {s} at {d}:{d}\n~{s}\n";
            break :blk try fmt.allocPrint(heap, fmt_str, .{
                datetime, level, src.file, src.line, src.column, msg
            });
        }
    };
}

/// # Formats the Additional User Defined Data
/// **Remarks:** Return value must be freed by the caller.
fn ctxFormat(data: []Ctx) !Str {
    const heap = Self.iso().heap.?;
    var list = std.ArrayList(u8).init(heap);

    try list.append('{');

    for (data) |ctx| {
        const fmt_str = "{s}: {s},";
        const out = try fmt.allocPrint(heap, fmt_str, .{ctx.name, ctx.value});
        defer heap.free(out);

        try list.appendSlice(out);
    }

    _ = list.pop();
    try list.append('}');

    return try list.toOwnedSlice();
}
