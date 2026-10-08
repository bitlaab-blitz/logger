//! # Cross-platform Logger (Singleton)
//! - Provides a set of utilities for application level logging and debugging

const std = @import("std");
const Io = std.Io;
const fs = std.fs;
const fmt = std.fmt;
const mem = std.mem;
const posix = std.posix;
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
const Handle = union(enum) { fd: i32, file: Io.File };

/// # Singleton Logging Manager
/// - `Aio` - An optional I/O executor, use **void** for blocking I/O
pub fn Logger(comptime Aio: type) type {
    return struct {
        const SingletonObject = struct {
            io: Io = undefined,
            heap: ?Allocator = null,
            output: OutputType = OutputType.Console,
            handle: ?Handle = null,
            on_test: bool = false,
            level: u8 = 0,
            /// Guards blocking writes (shared `stdout` / file position)
            mutex: Io.Mutex = .init,
            /// Next append position in bytes - `io_uring` writes are
            /// `pwrite`, which ignores `O_APPEND`, so async, blocking and
            /// fallback writes all reserve their range from this counter
            file_offset: std.atomic.Value(u64) = .init(0)
        };

        var so = SingletonObject {};

        const Self = @This();

        /// # Initializes the Global Logger
        /// - `file` - Absolute path of the given log file
        /// - `levels` - One or more log level text (e.g., `DEBUG`)
        /// - `on_test` - Determines if currently used in a unit test
        pub fn init(
            io: Io,
            heap: Allocator,
            file: ?Str,
            levels: []const Str,
            on_test: bool
        ) !void {
            const sop = Self.iso();

            if (sop.handle != null) @panic("Initialize Only Once Per Process!");

            // Validates levels first, into a local mask - an invalid entry
            // must not leave a half-opened file behind nor pollute the level
            // flags of a subsequent retry
            var mask: u8 = 0;

            for (levels) |level| {
                if (mem.eql(u8, level, "DEBUG")) mask |= DEBUG
                else if (mem.eql(u8, level, "INFO")) mask |= INFO
                else if (mem.eql(u8, level, "WARN")) mask |= WARN
                else if (mem.eql(u8, level, "ERROR")) mask |= ERROR
                else if (mem.eql(u8, level, "FATAL")) mask |= FATAL
                else return Error.InvalidLogLevel;
            }

            // Prepares the new state locally - every fallible step runs
            // before anything is committed, so a failure leaves the previous
            // state (or the pristine one) fully intact for a clean retry
            var new_output = OutputType.Console;
            var new_handle: Handle = .{.file = Io.File.stdout()};
            var seed: ?u64 = null;

            if (file) |path| {
                const pathZ = try heap.dupeSentinel(u8, path, 0);
                defer heap.free(pathZ);

                const mode = 0o644; // For setting file permission (octal)

                if (builtin.os.tag == .linux and Aio != void) {
                    const linux = std.os.linux;
                    const flags = std.os.linux.O {
                        .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true
                    };
                    const rv = linux.openat(fs.cwd().fd, pathZ, flags, mode);
                    const res: isize = @bitCast(rv);

                    if (res < 0) {
                        utils.syscallError(@truncate(res), @src());
                        return Error.FailedToOpenLogFile;
                    }

                    const fd: i32 = @truncate(res);

                    // Seeds the append offset with the current file size
                    const pos: isize = @bitCast(linux.lseek(fd, 0, linux.SEEK.END));
                    if (pos < 0) {
                        std.debug.assert(linux.close(fd) == 0);
                        utils.syscallError(@truncate(pos), @src());
                        return Error.FailedToOpenLogFile;
                    }

                    new_handle = .{.fd = fd};
                    seed = @intCast(pos);
                } else {
                    const rv = try Io.Dir.cwd().createFile(io, pathZ, .{
                        .truncate = false, .read = false
                    });

                    new_handle = .{.file = rv};
                }

                new_output = OutputType.File;
            }

            sop.io = io;
            sop.heap = heap;
            sop.on_test = on_test;
            sop.level = mask;
            sop.handle = new_handle;
            sop.output = new_output;

            if (seed) |pos| sop.file_offset.store(pos, .monotonic);
        }

        /// # Destroys the Global Logger
        /// **Remarks:** Safe to call multiple times, and `init` afterwards.
        pub fn deinit() void {
            const sop = Self.iso();

            const handle = sop.handle orelse return;
            sop.handle = null;

            switch (handle) {
                .file => |file| {
                    // `stdout` must never be closed
                    if (sop.output == .File) file.close(sop.io);
                },
                .fd => |fd| {
                    if (builtin.os.tag == .linux and Aio != void) {
                        const rv = std.os.linux.close(fd);
                        const res: isize = @bitCast(rv);

                        // `EINTR` still closes the descriptor on Linux
                        if (res < 0 and
                            res != -@as(isize, @intFromEnum(posix.E.INTR))
                        ) {
                            utils.syscallError(@truncate(rv), @src());
                        }
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
                    utils.oom(sop.io, @src());
                };
                defer heap.free(data);

                const out = format("DEBUG", data, ctx, src) catch |e| {
                    utils.unrecoverable(sop.io, e, @src());
                };

                log(out, false) catch |e| {
                    utils.unrecoverable(sop.io, e, @src());
                };
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
                    utils.oom(sop.io, @src());
                };
                defer heap.free(data);

                const out = format("INFO", data, ctx, src) catch |e| {
                    utils.unrecoverable(sop.io, e, @src());
                };

                log(out, false) catch |e| {
                    utils.unrecoverable(sop.io, e, @src());
                };
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
                    utils.oom(sop.io, @src());
                };
                defer heap.free(data);

                const out = format("WARN", data, ctx, src) catch |e| {
                    utils.unrecoverable(sop.io, e, @src());
                };

                log(out, false)  catch |e| {
                    utils.unrecoverable(sop.io, e, @src());
                };
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
                    utils.oom(sop.io, @src());
                };
                defer heap.free(data);

                const out = format("ERROR", data, ctx, src) catch |e| {
                    utils.unrecoverable(sop.io, e, @src());
                };

                log(out, false)  catch |e| {
                    utils.unrecoverable(sop.io, e, @src());
                };
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
                    utils.oom(sop.io, @src());
                };
                defer heap.free(data);

                const out = format("FATAL", data, ctx, src) catch |e| {
                   utils.unrecoverable(sop.io, e, @src());
                };

                log(out, true) catch |e| {
                    utils.unrecoverable(sop.io, e, @src());
                };
            }
        }

        /// # Dispatches A Formatted Log Entry
        /// **Remarks:** Takes ownership of `data` on every code path.
        fn log(data: Str, blocking: bool) !void {
            const sop = Self.iso();
            const heap = sop.heap.?;

            if (sop.on_test) {
                // Writing to `StdOut` in unit tests is currently illegal
                // → skips the following code when called on unit testing
                heap.free(data);
                return;
            }

            // Async submission is only possible while the event loop runs
            const can_async = !blocking
                and builtin.os.tag == .linux
                and Aio != void
                and sop.output == .File
                and Aio.evlStatus() == .running;

            if (can_async) {
                // Reserves a private byte range per entry so concurrent
                // writes never overlap, regardless of completion order
                const offset = sop.file_offset.fetchAdd(data.len, .monotonic);

                const entry = try heap.create(Log);
                errdefer heap.destroy(entry);
                entry.* = .{.data = data};
                errdefer heap.free(data);

                const fd = sop.handle.?.fd;
                try Aio.write(free, @as(?*anyopaque, entry), .{
                    .fd = fd, .buff = data, .count = data.len, .offset = offset
                });
                return; // Ownership of `data` moves to `free()`
            }

            // Non-async paths free `data` on return; the async branch above
            // transfers ownership to the completion callback instead
            defer heap.free(data);

            // Blocking and fallback writes serialize on the same lock
            sop.mutex.lockUncancelable(sop.io);
            defer sop.mutex.unlock(sop.io);

            if (blocking) {
                // Fatal logs are always blocking and only written to `stdOut`
                try Io.File.stdout().writeStreamingAll(sop.io, data);
                return;
            }

            // Entries are dropped after `deinit` instead of crashing on a
            // null handle (fatal entries bypass this - they use raw `stdout`)
            const handle = sop.handle orelse return;

            if (sop.output == .File) {
                switch (handle) {
                    .fd => |fd| {
                        // Fallback write while async entries may still be in
                        // flight - keeps using the shared offset counter
                        const offset = sop.file_offset.fetchAdd(
                            data.len, .monotonic
                        );

                        const file: Io.File = .{
                            .handle = fd, .flags = .{.nonblocking = false}
                        };

                        try file.writePositionalAll(sop.io, data, offset);
                    },
                    .file => |file| {
                        const end = try file.length(sop.io);
                        try file.writePositionalAll(sop.io, data, end);
                    },
                }
            } else {
                try handle.file.writeStreamingAll(sop.io, data);
            }
        }

        /// # Frees A Completed Async Log Entry
        fn free(cqe_res: i32, userdata: ?*anyopaque) void {
            const heap = Self.iso().heap.?;

            const entry: *Log = @ptrCast(@alignCast(userdata.?));
            defer heap.destroy(entry);

            if (cqe_res < 0) {
                utils.syscallError(cqe_res, @src());
                std.log.err("~ Async log write failed, {d} bytes lost", .{entry.data.len});
            } else if (@as(usize, @intCast(cqe_res)) < entry.data.len) {
                std.log.warn(
                    "Partial async log write - {d}/{d} bytes",
                    .{@as(usize, @intCast(cqe_res)), entry.data.len}
                );
            }

            heap.free(entry.data);
        }

        fn format(level: Str, msg: Str, data: ?[]const Ctx, src: SrcLoc) !Str {
            const heap = Self.iso().heap.?;
            const datetime = DateTime.now(Self.iso().io).toLocal(.BST);

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
            var list: ArrayList(u8) = .empty;
            errdefer list.deinit(heap);

            try list.append(heap, '{');

            for (data, 0..) |ctx, i| {
                if (i != 0) try list.appendSlice(heap, ", ");

                const out = try fmt.allocPrint(
                    heap, "{s}: {s}", .{ctx.name, ctx.value}
                );
                defer heap.free(out);
                try list.appendSlice(heap, out);
            }

            try list.append(heap, '}');
            return try list.toOwnedSlice(heap);
        }
    };
}
