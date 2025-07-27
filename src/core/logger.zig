//! # Cross-platform Logger (Singleton)
//! - Provides a set of utilities for application level logging and debugging

const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;
const mem = std.mem;
const File = fs.File;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const SrcLoc = std.builtin.SourceLocation;

const builtin = @import("builtin");

const utils = @import("./utils.zig");
const DateTime = @import("./datetime.zig");


const Error = error { InvalidLogLevel, FailedToOpenLogFile };

const DEBUG = 1 << 0;
const INFO  = 1 << 1;
const WARN  = 1 << 2;
const ERROR = 1 << 3;
const FATAL = 1 << 4;

const Str = []const u8;

const Log = struct { data: Str };
const Ctx = struct { name: Str, value: Str };

const OutputType = enum { Console, File };
const Handle = union(enum) { fd: i32, file: File };

/// # Singleton Logging Manager
/// - `Aio` - An optional I/O executor, use **void** for blocking I/O
pub fn Logger(comptime Aio: type) type {
    return struct {
        const SingletonObject = struct {
            heap: ?Allocator = null,
            output: OutputType = OutputType.Console,
            handle: ?Handle = null,
            on_test: bool = false,
            level: u8 = 0
        };

        var so = SingletonObject {};

        const Self = @This();

        /// # Initializes the Global Logger
        /// - `file` - Absolute path of the given log file
        /// - `levels` - One or more log level text (e.g., `DEBUG`)
        /// - `on_test` - Determines if currently used in a unit test
        pub fn init(
            heap: Allocator,
            file: ?Str,
            levels: []const Str,
            on_test: bool
        ) !void {
            const sop = Self.iso();

            if (sop.handle != null) @panic("Initialize Only Once Per Process!");

            sop.heap = heap;
            sop.on_test = on_test;

            if (file) |path| {
                sop.output = OutputType.File;
                const pathZ = try heap.dupeZ(u8, path);
                defer heap.free(pathZ);

                const mode = 0o644; // For setting file permission (octal)

                if (builtin.os.tag == .linux and Aio != void) {
                    const linux = std.os.linux;
                    const flags = std.os.linux.O {
                        .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true
                    };
                    const rv = linux.openat(fs.cwd().fd, pathZ, flags, mode);
                    const res: isize = @bitCast(rv);

                    if (res <= 0) {
                        utils.syscallError(@truncate(res), @src());
                        return Error.FailedToOpenLogFile;
                    }

                    sop.handle = .{.fd = @truncate(res)};
                } else {
                    const rv = try std.fs.cwd().createFileZ(pathZ, .{
                        .truncate = false, .read = false, .mode = mode
                    });

                    sop.handle = .{.file = rv};
                }
            } else {
                sop.handle = .{.file = std.io.getStdOut() };
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
            if (sop.output == .Console) return;

            switch (sop.handle.?) {
                .file => |file| file.close(),
                .fd => |fd| {
                    if (builtin.os.tag == .linux and Aio != void) {
                        std.debug.assert(std.os.linux.close(fd) == 0);
                    } else unreachable;
                }
            }
        }

        /// # Returns Internal Static Object
        pub fn iso() *SingletonObject { return &Self.so; }

        /// # Writes Debug Log
        /// **Remarks:** Skips logging when `DEBUG` level is inactive.
        pub fn debug(
            comptime msg: Str,
            args: anytype,
            ctx: ?[]const Ctx,
            src: SrcLoc
        ) void {
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

        /// # Writes Information Log
        /// **Remarks:** Skips logging when `INFO` level is inactive.
        pub fn info(
            comptime msg: Str,
            args: anytype,
            ctx: ?[]const Ctx,
            src: SrcLoc
        ) void {
            const sop = Self.iso();

            if (sop.level & INFO == INFO) {
                const heap = sop.heap.?;
                const data = fmt.allocPrint(heap, msg, args) catch {
                    utils.oom(@src());
                };
                defer heap.free(data);

                const out = format("INFO", data, ctx, src) catch |e| {
                    utils.unrecoverable(e, @src());
                    return;
                };

                log(out, false) catch |e| utils.unrecoverable(e, @src());
            }
        }

        /// # Writes Warning Log
        /// **Remarks:** Skips logging when `WARN` level is inactive.
        pub fn warn(
            comptime msg: Str,
            args: anytype,
            ctx: ?[]const Ctx,
            src: SrcLoc
        ) void {
            const sop = Self.iso();

            if (sop.level & WARN == WARN) {
                const heap = sop.heap.?;
                const data = fmt.allocPrint(heap, msg, args) catch {
                    utils.oom(@src());
                };
                defer heap.free(data);

                const out = format("WARN", data, ctx, src) catch |e| {
                    utils.unrecoverable(e, @src());
                };

                log(out, false)  catch |e| utils.unrecoverable(e, @src());
            }
        }

        /// # Writes Error Log
        /// **Remarks:** Skips logging when `ERROR` level is inactive.
        pub fn err(
            comptime msg: Str,
            args: anytype,
            ctx: ?[]const Ctx,
            src: SrcLoc
        ) void {
            const sop = Self.iso();

            if (sop.level & ERROR == ERROR) {
                const heap = sop.heap.?;
                const data = fmt.allocPrint(heap, msg, args) catch {
                    utils.oom(@src());
                };
                defer heap.free(data);

                const out = format("ERROR", data, ctx, src) catch |e| {
                    utils.unrecoverable(e, @src());
                };

                log(out, false)  catch |e| utils.unrecoverable(e, @src());
            }
        }

        /// # Writes Fatal Log
        /// **Remarks:** Skips logging when `FATAL` level is inactive.
        /// Fatal logs are always blocking and only written to the `stdOut`.
        pub fn fatal(
            comptime msg: Str,
            args: anytype,
            ctx: ?[]const Ctx,
            src: SrcLoc
        ) void {
            const sop = Self.iso();

            if (sop.level & FATAL == FATAL) {
                const heap = sop.heap.?;
                const data = fmt.allocPrint(heap, msg, args) catch {
                    utils.oom(@src());
                };
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

            if (blocking or Aio != void and Aio.evlStatus() == .closed) {
                defer heap.free(data);

                if (sop.on_test) return;
                // Writing to `StdOut` in unit tests is currently illegal
                // ↓ skips the following code when called on unit testing

                var std_out = std.io.getStdOut().writer();
                try std_out.print("{s}", .{data});
                return;
            }

            if (builtin.os.tag == .linux and Aio != void) {
                const log_data = try heap.create(Log);
                log_data.* = .{.data = data};

                const fd = sop.handle.?.fd;
                try Aio.write(free, @as(?*anyopaque, log_data), .{
                    .fd = fd, .buff = data, .count = data.len, .offset = 0
                });
            } else {
                if (sop.output == .File) try sop.handle.?.file.seekFromEnd(0);
                const file = sop.handle.?.file.writer();
                std.debug.assert(try file.write(data) == data.len);

                heap.free(data);
            }
        }

        fn free(cqe_res: i32, userdata: ?*anyopaque) void {
            std.debug.assert(cqe_res > 0);
            const heap = Self.iso().heap.?;

            const log_data: *Log = @ptrCast(@alignCast(userdata));
            heap.free(log_data.data);
            heap.destroy(log_data);
        }

        fn format(level: Str, msg: Str, data: ?[]const Ctx, src: SrcLoc) !Str {
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
        fn ctxFormat(data: []const Ctx) !Str {
            const heap = Self.iso().heap.?;
            var list = std.ArrayList(u8).init(heap);

            try list.append('{');

            for (data) |ctx| {
                const fmt_str = "{s}: {s}, ";
                const out = try fmt.allocPrint(
                    heap, fmt_str, .{ctx.name, ctx.value}
                );
                defer heap.free(out);
                try list.appendSlice(out);
            }

            _ = list.pop();
            _ = list.pop();
            try list.append('}');

            return try list.toOwnedSlice();
        }
    };
}
