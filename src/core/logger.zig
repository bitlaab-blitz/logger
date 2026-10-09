//! # Cross-platform Logger (Singleton)
//! - Provides a set of utilities for application level logging and debugging

const std = @import("std");
const Io = std.Io;
const fs = std.fs;
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
            /// fallback writes all reserve their range from this counter.
            /// Cache-line aligned - hot-written per async write while the
            /// neighboring fields (e.g., `level`) are read per log call
            file_offset: std.atomic.Value(u64) align(64) = .init(0)
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

                    // Seeds the shared append offset - lets blocking and
                    // fallback writes skip a per-entry `length` syscall
                    const len = rv.length(io) catch |e| {
                        rv.close(io);
                        return e;
                    };

                    new_handle = .{.file = rv};
                    seed = len;
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
            writeLog("DEBUG", DEBUG, false, msg, args, ctx, src);
        }

        /// # Writes Information Log
        /// **Remarks:** Skips logging when `INFO` level is inactive.
        pub fn info(
            comptime msg: Str,
            args: anytype,
            ctx: ?[]const Ctx,
            src: SrcLoc
        ) void {
            writeLog("INFO", INFO, false, msg, args, ctx, src);
        }

        /// # Writes Warning Log
        /// **Remarks:** Skips logging when `WARN` level is inactive.
        pub fn warn(
            comptime msg: Str,
            args: anytype,
            ctx: ?[]const Ctx,
            src: SrcLoc
        ) void {
            writeLog("WARN", WARN, false, msg, args, ctx, src);
        }

        /// # Writes Error Log
        /// **Remarks:** Skips logging when `ERROR` level is inactive.
        pub fn err(
            comptime msg: Str,
            args: anytype,
            ctx: ?[]const Ctx,
            src: SrcLoc
        ) void {
            writeLog("ERROR", ERROR, false, msg, args, ctx, src);
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
            writeLog("FATAL", FATAL, true, msg, args, ctx, src);
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
                        // Reserves from the shared counter - avoids a
                        // per-entry `length` syscall and stays consistent
                        // with async and fallback writes
                        const offset = sop.file_offset.fetchAdd(
                            data.len, .monotonic
                        );

                        try file.writePositionalAll(sop.io, data, offset);
                    }
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

        /// # Builds The Final Log Line In A Single Pass
        /// **Remarks:** One growing buffer serves the whole entry - the
        /// message is formatted straight into it, so there are no
        /// intermediate allocations nor copies. Return value must be freed
        /// by the caller.
        fn build(
            comptime label: Str,
            comptime msg: Str,
            args: anytype,
            ctx: ?[]const Ctx,
            src: SrcLoc
        ) !Str {
            const sop = Self.iso();
            const heap = sop.heap.?;

            var list: ArrayList(u8) = .empty;
            errdefer list.deinit(heap);

            try DateTime.now(sop.io).formatLocal(.BST, heap, &list);

            try list.print(heap, " [{s}] {s} at {d}:{d}\n", .{
                label, src.file, src.line, src.column
            });

            if (ctx) |entries| {
                try list.append(heap, '{');

                for (entries, 0..) |entry, i| {
                    if (i != 0) try list.appendSlice(heap, ", ");
                    try list.print(heap, "{s}: {s}", .{entry.name, entry.value});
                }

                try list.appendSlice(heap, "}\n");
            }

            try list.print(heap, "~" ++ msg, args);
            try list.append(heap, '\n');

            return list.toOwnedSlice(heap);
        }

        /// # Shared Body Of All Level Functions
        /// **Remarks:** The level check runs first, so an inactive level
        /// costs a single load-and-compare before anything is formatted
        fn writeLog(
            comptime label: Str,
            comptime mask: u8,
            comptime blocking: bool,
            comptime msg: Str,
            args: anytype,
            ctx: ?[]const Ctx,
            src: SrcLoc
        ) void {
            const sop = Self.iso();

            if (sop.level & mask != mask) return;

            const out = build(label, msg, args, ctx, src) catch {
                utils.oom(sop.io, @src());
            };

            log(out, blocking) catch |e| {
                utils.unrecoverable(sop.io, e, @src());
            };
        }
    };
}
