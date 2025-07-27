//! # Utility Module

const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;
const log = std.log;
const mem = std.mem;
const linux = std.os.linux;
const Allocator = mem.Allocator;
const SrcLoc = std.builtin.SourceLocation;

const DateTime = @import("./datetime.zig");

/// # Logs Syscall Error Number
/// - e.g., Bad file descriptor (EBADF) - `utils.syscallError(9, @src());`
pub fn syscallError(code: i32, src: SrcLoc) void {
    const err: linux.E = @enumFromInt(@as(u16, @truncate(@abs(code))));
    const fmt_str = "Syscall - Errno {d} E{s} occurred in {s} at line {d}";
    log.err(fmt_str, .{code, @tagName(err), src.file, src.line});
}

/// # Out of Memory Error
/// **Remarks:** Exhausting memory means that all bets are off. Handling
/// fallible memory allocations often leads to code complexity and sometimes
/// not worth the effort. However, be cautious about the potential data lose!
pub fn oom(src: SrcLoc) noreturn {
    const datetime = DateTime.now().toLocal(.BST);
    const fmt_str = "{s} [FATAL] {s} at {d}:{d}\n";
    log.info(fmt_str, .{datetime, src.file, src.line, src.column});
    log.err("~ Out Of Memory", .{});
    std.process.exit(255);
}

/// # App Abruptly Exits
///
/// **Remarks:** `@panic()` and `std.debug.panic()` has inconstancy.
/// Process doesn't exit completely when calling from detached threads.
pub fn panic(comptime format: []const u8, args: anytype, src: SrcLoc) noreturn {
    const datetime = DateTime.now().toLocal(.BST);
    const fmt_str = "{s} [FATAL] {s} at {d}:{d}\n";
    log.info(fmt_str, .{datetime, src.file, src.line, src.column});
    log.err(format, args);
    std.process.exit(254);
}

/// # Unrecoverable Error Handle
/// **Remarks:** Prevents unnecessary code repetition when needed multiple times
pub fn unrecoverable(err: anyerror, src: SrcLoc) noreturn {
    panic("~ {s}", .{@errorName(err)}, src);
}
