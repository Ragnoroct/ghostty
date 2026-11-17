//! GTK window snapshot primitives. All mutation belongs to the GTK main thread.
const std = @import("std");
const global = @import("../../global.zig");

/// Timestamp plus 64 random bits avoids collisions between simultaneous processes
/// and restarts, unlike a timestamp plus process-local 16-bit counter. Within a
/// process the value increases even if the wall clock moves backwards.
pub const Id = [32]u8;
var previous_id: u128 = 0;
pub fn newId() Id {
    const wall_ms: u64 = @intCast(@max(0, std.Io.Timestamp.now(global.io(), .real).toMilliseconds()));
    return nextId(&previous_id, wall_ms, randomU64());
}
fn nextId(previous: *u128, wall_ms: u64, entropy: u64) Id {
    const candidate = (@as(u128, wall_ms) << 64) | entropy;
    previous.* = @max(previous.* + 1, candidate);
    return hexId(previous.*);
}
fn hexId(value: u128) Id {
    var buf: Id = undefined;
    _ = std.mem.print(&buf, "{x:0>32}", .{value}) catch unreachable;
    return buf;
}

pub const Scheduler = struct {
    structural_first: ?i64 = null,
    structural_due: ?i64 = null,
    soft: bool = false,
    soft_last: i64 = -30_000,
    heartbeat_last: i64 = -30_000,
    input: i64 = 0,
    heartbeat_input: i64 = 0,

    pub fn structural(self: *Scheduler, now: i64) void {
        if (self.structural_first == null) self.structural_first = now;
        self.structural_due = @min(now + 1500, self.structural_first.? + 10_000);
    }
    pub const Due = struct {
        structural: bool,
        soft: bool,
        heartbeat: bool,
        pub fn any(self: Due) bool {
            return self.structural or self.soft or self.heartbeat;
        }
    };
    pub fn due(self: *const Scheduler, now: i64) Due {
        return .{
            .structural = if (self.structural_due) |v| now >= v else false,
            .soft = self.soft and now - self.soft_last >= 30_000,
            .heartbeat = self.input != self.heartbeat_input and now - self.heartbeat_last >= 30_000,
        };
    }
    pub fn flushed(self: *Scheduler, now: i64, why: Due) void {
        if (why.structural) {
            self.structural_first = null;
            self.structural_due = null;
        }
        if (why.structural or why.soft) {
            self.soft = false;
            self.soft_last = now;
        }
        if (why.heartbeat) {
            self.heartbeat_last = now;
            self.heartbeat_input = self.input;
        }
    }
};

pub fn timestamp(ms: i64) [24]u8 {
    const n: u64 = @intCast(@max(0, ms));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = n / 1000 };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const seconds = epoch.getDaySeconds();
    var buf: [24]u8 = undefined;
    _ = std.mem.print(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        day.year,                  @backingInt(month.month),     month.day_index + 1,
        seconds.getHoursIntoDay(), seconds.getMinutesIntoHour(), seconds.getSecondsIntoMinute(),
        n % 1000,
    }) catch unreachable;
    return buf;
}

/// Linux comm may contain spaces and ')' characters. Fields after its LAST ')'
/// begin at field 3; starttime is field 22.
pub fn startTicks(stat: []const u8) !u64 {
    const end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.InvalidStat;
    var it = std.mem.tokenizeScalar(u8, stat[end + 1 ..], ' ');
    var field: usize = 3;
    while (it.next()) |s| : (field += 1) {
        if (field == 22) return std.fmt.parseInt(u64, s, 10);
    }
    return error.InvalidStat;
}
pub fn processTicks(alloc: std.mem.Allocator, pid: i32) !u64 {
    var path: [64]u8 = undefined;
    const name = try std.mem.print(&path, "/proc/{d}/stat", .{pid});
    const file = try std.Io.Dir.cwd().openFile(global.io(), name, .{});
    defer file.close(global.io());
    const bytes = try @import("../../lib/compat/file.zig").readToEndAlloc(file, alloc, 8192);
    defer alloc.free(bytes);
    return startTicks(bytes);
}

// Retain closed windows for seven days and inactive windows for thirty days.
// These are deliberately constants, not environment-controlled test shortcuts.
pub const closed_days = 7;
pub const idle_days = 30;
pub fn collect(alive: bool, now: i64, closed: ?i64, active: i64) bool {
    if (alive) return false;
    const day = 86_400_000;
    return (if (closed) |v| now - v > closed_days * day else false) or now - active > idle_days * day;
}

test "window state: ids are ordered, unique and hex round trip" {
    const a = newId();
    const b = newId();
    try std.testing.expect(std.mem.order(u8, &a, &b) == .lt);
    try std.testing.expectEqual(b, hexId(try std.fmt.parseInt(u128, &b, 16)));
}
test "window state: heartbeat leading and trailing edges are independent of structural writes" {
    var s: Scheduler = .{};
    try std.testing.expect(!s.due(0).any());
    s.input = 123;
    try std.testing.expect(s.due(0).heartbeat);
    s.flushed(0, s.due(0));
    s.input = 124;
    s.structural(100);
    s.flushed(1600, s.due(1600));
    try std.testing.expect(!s.due(29_999).heartbeat);
    try std.testing.expect(s.due(30_000).heartbeat);
    s.flushed(30_000, s.due(30_000));
    try std.testing.expectEqual(@as(i64, 124), s.heartbeat_input);
    try std.testing.expect(!s.due(60_000).any());
}
test "window state: sustained input has at most three heartbeats in ninety seconds" {
    var s: Scheduler = .{};
    var count: usize = 0;
    var now: i64 = 0;
    while (now < 90_000) : (now += 50) {
        s.input = now + 1;
        const d = s.due(now);
        if (d.heartbeat) count += 1;
        s.flushed(now, d);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}
test "window state: structural debounce max wait and soft rate limit" {
    var s: Scheduler = .{};
    s.structural(0);
    var now: i64 = 0;
    while (now < 10_000) : (now += 100) {
        s.structural(now);
        try std.testing.expect(!s.due(now).structural);
    }
    try std.testing.expect(s.due(10_000).structural);
    s.flushed(10_000, s.due(10_000));
    s.soft = true;
    try std.testing.expect(!s.due(39_999).soft);
    try std.testing.expect(s.due(40_000).soft);
}
test "window state: retention never collects live windows" {
    const day = 86_400_000;
    try std.testing.expect(!collect(true, 100 * day, 0, 0));
    try std.testing.expect(collect(false, 8 * day, 0, 7 * day));
    try std.testing.expect(!collect(false, 6 * day, 0, 0));
    try std.testing.expect(collect(false, 31 * day, null, 0));
    try std.testing.expect(!collect(false, 30 * day, null, 0));
}
test "window state: UTC timestamp" {
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.123Z", &timestamp(123));
}
test "window state: proc stat comm can contain spaces and parentheses" {
    try std.testing.expectEqual(@as(u64, 999), try startTicks("123 (a ) b) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 999 0"));
    try std.testing.expectError(error.InvalidStat, startTicks("garbage"));
}

test "window state: simulated restart and backward clock" {
    var first: u128 = 0;
    var restarted: u128 = 0;
    const a = nextId(&first, 1000, 123);
    const b = nextId(&restarted, 1000, 456);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
    const c = nextId(&first, 999, 123);
    try std.testing.expect(std.mem.order(u8, &a, &c) == .lt);
}

fn randomU64() u64 {
    var value: u64 = undefined;
    global.io().random(std.mem.asBytes(&value));
    return value;
}

test "window state: live proc start ticks" {
    const pid: i32 = @intCast(std.os.linux.getpid());
    try std.testing.expect(try processTicks(std.testing.allocator, pid) > 0);
}
