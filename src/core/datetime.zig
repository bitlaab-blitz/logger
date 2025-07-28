//! # ISO-8601 Date Time - v1.0.1
//! - Provides a set of utilities for managing dates, time, and time zones.

const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const time = std.time;
const testing = std.testing;


const Error = error { InvalidInput, InvalidFormat, UnknownUtcOffset, TBEpoch };

pub const TimeZone = enum {
    /// Coordinated Universal Time
    UTC,
    /// Bangladesh Standard Time
    BST,
    /// Central Standard Time - North America
    CST,
    /// Indian Standard Time
    IST,
    /// Singapore Time
    SGT,
};

year: u16 = 1970,
month: u8 = 1,
day: u8 = 1,
hour: u8 = 0,
minute: u8 = 0,
second: u8 = 0,
millisecond: u16 = 0,
timezone: TimeZone = .UTC,

const Self = @This();

/// # Current Date and Time
pub fn now() Self {
    const stamp: u64 = @intCast(time.milliTimestamp());
    return fromTimestamp(stamp);
}

/// # Specific Date and Time
pub fn fromTimestamp(epoch_ms: u64) Self {
    var datetime = Self {};
    var stamp: u64 = epoch_ms;

    datetime.addMilliseconds(&stamp);
    datetime.addSeconds(&stamp);
    datetime.addMinutes(&stamp);
    datetime.addHours(&stamp);
    datetime.addDate(&stamp);

    return datetime;
}

fn addMilliseconds(self: *Self, ts: *u64) void {
    self.millisecond = @intCast(ts.* % 1000);
    ts.* /= 1000;
}

fn addSeconds(self: *Self, ts: *u64) void {
    self.second = @intCast(ts.* % 60);
    ts.* /= 60;
}

fn addMinutes(self: *Self, ts: *u64) void {
    self.minute = @intCast(ts.* % 60);
    ts.* /= 60;
}

fn addHours(self: *Self, ts: *u64) void {
    self.hour = @intCast(ts.* % 24);
    ts.* /= 24;
}

/// # Calculates Date Since Epoch
fn addDate(self: *Self, ts: *u64) void {
    // Adds the years from 1970 up to the current year
    while (true) {
        const days: u16 = if (self.isLeapYear()) 366 else 365;
        if (ts.* >= days) {
            self.year += 1;
            ts.* -= days;
            continue;
        }
        break;
    }

    // Adds the remaining months up to the current month
    while (true) {
        const days = self.daysThisMonth();
        if (ts.* >= days) {
            self.month += 1;
            ts.* -= days;

            if (self.month > 12) {
                self.year += 1;
                self.month = 1;
            }
            continue;
        }
        break;
    }

    // Adjusts remaining days, months and years

    const days = self.daysThisMonth();
    if (self.day + ts.* > days) {
        ts.* -= days - self.day;
        self.month += 1;
        self.day = 1;
    }

    self.day += @intCast(ts.*);

    if (self.day > self.daysThisMonth()) {
        self.month += 1;
        self.day = 1;
    }

    if (self.month > 12) {
        self.year += 1;
        self.month = 1;
    }
}

/// # Specific Date and Time
/// **Remarks:** Input values must be given in UTC
pub fn new(year: u16, month: u8, day: u8, hour: u8, min: u8, sec: u8) !Self {
    if (!(year >= 1970)) return Error.TBEpoch; // Time Before Epoch
    if (!(month > 0 and month <= 12) or
        !(day > 0 and day <= 31) or
        !(hour < 24) or
        !(min < 60) or
        !(sec < 60))
    {
        return Error.InvalidInput;
    }

    var datetime = Self {
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = min,
        .second = sec,
    };

    if (datetime.day > datetime.daysThisMonth()) return Error.InvalidInput;
    if (datetime.month == 2 and datetime.day == 29) {
        if(!datetime.isLeapYear()) return Error.InvalidInput;
    }

    return datetime;
}

/// # ISO-8601 Formatted Date and Time
/// - e.g., `1993-09-23T15:45:30.500Z` for Zulu
/// - e.g., `1993-09-23T15:45:30.500+06:00` for UTC offset
pub fn from(fmt_str: []const u8) !Self {
    var zone: TimeZone = undefined;
    switch (fmt_str.len) {
        24 => {
            if (fmt_str[23] == 'Z') zone = .UTC
            else return Error.InvalidFormat;
        },
        29 => {
            if (mem.eql(u8, fmt_str[23..], "+00:00")) zone = .UTC
            else if (mem.eql(u8, fmt_str[23..], "+06:00")) zone = .BST
            else if (mem.eql(u8, fmt_str[23..], "-06:00")) zone = .CST
            else if (mem.eql(u8, fmt_str[23..], "+05:30")) zone = .IST
            else if (mem.eql(u8, fmt_str[23..], "+08:00")) zone = .SGT
            else return Error.UnknownUtcOffset;
        },
        else => return Error.InvalidFormat
    }

    if (!(fmt_str[4] == '-') or
        !(fmt_str[7] == '-') or
        !(fmt_str[10] == 'T') or
        !(fmt_str[13] == ':') or
        !(fmt_str[16] == ':') or
        !(fmt_str[19] == '.'))
    {
        return Error.InvalidFormat;
    }

    const year = try fmt.parseInt(u16, fmt_str[0..4], 10);
    const month = try fmt.parseInt(u8, fmt_str[5..7], 10);
    const day = try fmt.parseInt(u8, fmt_str[8..10], 10);
    const hour = try fmt.parseInt(u8, fmt_str[11..13], 10);
    const min = try fmt.parseInt(u8, fmt_str[14..16], 10);
    const sec = try fmt.parseInt(u8, fmt_str[17..19], 10);
    const ms = try fmt.parseInt(u16, fmt_str[20..23], 10);

    var datetime = try Self.new(year, month, day, hour, min, sec);
    datetime.millisecond = ms;
    datetime.timezone = zone;
    return datetime;
}

/// # ISO-8601 Formatted Date and Time (Zulu)
pub fn toUtc(self: *const Self) [24]u8 {
    var buffer: [24]u8 = undefined;
    const fmt_str = "{}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>3}Z";
    _ = fmt.bufPrint(&buffer, fmt_str, .{
        self.year,
        self.month,
        self.day,
        self.hour,
        self.minute,
        self.second,
        self.millisecond,
    }) catch |err| @panic(@errorName(err));

    return buffer;
}

/// # ISO-8601 Formatted Date and Time
pub fn toUtcOffset(self: *const Self) [29]u8 {
    var buffer: [29]u8 = undefined;
    const offset = switch (self.timezone) {
        .UTC => "+00:00",
        .BST => "+06:00",
        .CST => "-06:00",
        .IST => "+05:30",
        .SGT => "+08:00",
    };

    const fmt_str = "{}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>3}{s}";
    _ = fmt.bufPrint(&buffer, fmt_str, .{
        self.year,
        self.month,
        self.day,
        self.hour,
        self.minute,
        self.second,
        self.millisecond,
        offset,
    }) catch |err| @panic(@errorName(err));

    return buffer;
}

/// # Custom Formatted Date and Time
/// - e.g., `1993-09-23 12:45:30 AM in UTC`
pub fn toLocal(self: *const Self, zone: ?TimeZone) [29]u8 {
    var timestamp: i64 = @intCast(self.toTimestamp());
    var timezone: []const u8 = undefined;

    switch (zone orelse self.timezone) {
        .UTC => timezone = @tagName(.UTC),
        .BST => {
            timestamp += 6 * time.ms_per_hour;
            timezone = @tagName(.BST);
        },
        .CST => {
            timestamp += -6 * time.ms_per_hour;
            timezone = @tagName(.CST);
        },
        .IST => {
            timestamp += 5 * time.ms_per_hour + 30 * time.ms_per_min;
            timezone = @tagName(.IST);
        },
        .SGT => {
            timestamp += 8 * time.ms_per_hour;
            timezone = @tagName(.SGT);
        }
    }

    var datetime = Self.fromTimestamp(@intCast(timestamp));
    const meridian = if (datetime.hour < 12) "AM" else "PM";
    switch (datetime.hour) {
        0 => datetime.hour = 12,
        else => { if (datetime.hour > 12) datetime.hour -= 12; }
    }

    var buffer: [29]u8 = undefined;
    const fmt_str = "{}-{:0>2}-{:0>2} {:0>2}:{:0>2}:{:0>2} {s} in {s}";
    _ = fmt.bufPrint(&buffer, fmt_str, .{
        datetime.year,
        datetime.month,
        datetime.day,
        datetime.hour,
        datetime.minute,
        datetime.second,
        meridian,
        timezone
    }) catch |err| @panic(@errorName(err));

    return buffer;
}

pub fn getTimezone(self: *const Self) TimeZone {
    return self.timezone;
}

/// # Epoch Time In Milliseconds
pub fn toTimestamp(self: *const Self) u64 {
    var timestamp: u64 = 0;
    const total_days = self.daysSinceEpoch();

    timestamp += total_days * time.ms_per_day;
    timestamp += @as(u64, self.hour) * time.ms_per_hour;
    timestamp += @as(u64, self.minute) * time.ms_per_min;
    timestamp += @as(u64, self.second) * time.ms_per_s;
    timestamp += @as(u64, self.millisecond);
    return timestamp;
}

fn daysSinceEpoch(self: *const Self) u64 {
    var total_days: u64 = 0;

    for (1970..self.year) |year| {
        total_days += if (calcLeapYear(@intCast(year))) 366 else 365;
    }

    for (1..self.month) |month| {
        total_days += calcDays(self.year, @intCast(month));
    }

    total_days += self.day;
    return total_days - 1;
}

test daysSinceEpoch {
    const datetime = try Self.new(2000, 1, 1, 0, 0, 0);
    try testing.expect(datetime.daysSinceEpoch() == 10957);
}

fn isLeapYear(self: *const Self) bool {
    return calcLeapYear(self.year);
}

fn daysThisMonth(self: *const Self) u8 {
    return calcDays(self.year, self.month);
}

fn calcDays(year: u16, month: u8) u8 {
    switch (month) {
        1, 3, 5, 7, 8, 10, 12 => return 31,
        4, 6, 9, 11 => return 30,
        2 => return if (calcLeapYear(year)) 29 else 28,
        else => unreachable,
    }
}

fn calcLeapYear(year: u16) bool {
    return (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0));
}

test calcLeapYear {
    // Regular leap years (divisible by 4)
    try testing.expect(calcLeapYear(2004));
    try testing.expect(calcLeapYear(2020));
    try testing.expect(calcLeapYear(2024));

    // Century non-leap years (divisible by 100, but not by 400)
    try testing.expect(!calcLeapYear(1900));
    try testing.expect(!calcLeapYear(2100));

    // Century leap years (divisible by 400)
    try testing.expect(calcLeapYear(1600));
    try testing.expect(calcLeapYear(2000));

    // Non-leap years (not divisible by 4)
    try testing.expect(!calcLeapYear(2018));
    try testing.expect(!calcLeapYear(2019));
}

test "demo" {
    const dt_1 = Self.now();
    try testing.expect(dt_1.getTimezone() == TimeZone.UTC);

    const dt_2 = try Self.new(2000, 1, 1, 0, 0, 0);
    try testing.expect(dt_2.toTimestamp() == 946684800000);

    const fmt_str_1 = "2000-01-01T00:00:00.000Z";
    const out_1 = dt_2.toUtc();
    try testing.expect(mem.eql(u8, &out_1, fmt_str_1));

    const fmt_str_2 = "2000-01-01T00:00:00.000+00:00";
    const out_2 = dt_2.toUtcOffset();
    try testing.expect(mem.eql(u8, &out_2, fmt_str_2));

    const fmt_str_3 = "2000-01-01 12:00:00 AM in UTC";
    const out_3 = dt_2.toLocal(null);
    try testing.expect(mem.eql(u8, &out_3, fmt_str_3));

    const fmt_str_4 = "1999-05-07T12:00:00.500Z";
    const dt_3 = try Self.from(fmt_str_4);
    try testing.expect(dt_3.toTimestamp() == 926078400500);

    const fmt_str_5 = "1999-05-07T12:00:00.500+06:00";
    const dt_4 = try Self.from(fmt_str_5);
    try testing.expect(dt_4.toTimestamp() == 926078400500);
    try testing.expect(dt_4.getTimezone() == TimeZone.BST);

    const timestamp = dt_4.toTimestamp();
    const dt_5 = Self.fromTimestamp(timestamp);
    try testing.expect(dt_5.toTimestamp() == 926078400500);

    const fmt_str_6 = "07-05-1999T12:00:00.500+06:00";
    try testing.expectError(Error.InvalidFormat, Self.from(fmt_str_6));

    try testing.expectError(Error.InvalidInput, Self.new(2018, 2, 29, 0, 0, 0));
    try testing.expectError(Error.TBEpoch, Self.new(1969, 1, 1, 0, 0, 0));
}
