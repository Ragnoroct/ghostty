//! Compose an opaque status prefix and a title without interpreting programs.
const std = @import("std");

pub const Override = struct {
    title: []const u8,
    status_updatable: bool = false,
};

/// Flags belong to the binding action, not to titles entered in the dialog.
/// An unflagged binding retains Ghostty's existing fixed-title behavior.
pub fn parseOverride(value: []const u8) Override {
    for ([_][]const u8{ "--status-updatable ", "--readonly ", "-- " }) |flag| {
        if (std.mem.startsWith(u8, value, flag)) return .{
            .title = value[flag.len..],
            .status_updatable = std.mem.eql(u8, flag, "--status-updatable "),
        };
    }
    return .{ .title = value };
}

pub fn writeTitle(
    writer: *std.Io.Writer,
    plain: []const u8,
    status: ?[]const u8,
    show_status: bool,
) std.Io.Writer.Error!void {
    if (show_status) {
        if (status) |value| {
            if (value.len > 0) {
                try writer.writeAll(value);
                try writer.writeByte(' ');
            }
        }
    }
    try writer.writeAll(plain);
}

fn expectTitle(expected: []const u8, plain: []const u8, status: ?[]const u8, show_status: bool) !void {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try writeTitle(&buf.writer, plain, status, show_status);
    try std.testing.expectEqualStrings(expected, buf.written());
}

test "title activity: arbitrary status prefixes are independent of titles" {
    try expectTitle("Building My project", "My project", "Building", true);
    try expectTitle("upload 40% My project", "My project", "upload 40%", true);
    try expectTitle("\xe2\x97\x90 dj", "dj", "\xe2\x97\x90", true);
    try expectTitle("custom", "custom", "", true);
    try expectTitle("custom", "custom", null, true);
    try expectTitle("custom", "custom", "Working", false);
    try expectTitle("original title", "original title", null, true);
}

test "title activity: readonly and status-updatable flags retain literal names" {
    const live = parseOverride("--status-updatable My tab");
    try std.testing.expect(live.status_updatable);
    try std.testing.expectEqualStrings("My tab", live.title);
    for ([_][]const u8{ "My tab", "--readonly My tab" }) |input| {
        const fixed = parseOverride(input);
        try std.testing.expect(!fixed.status_updatable);
        try std.testing.expectEqualStrings("My tab", fixed.title);
    }
    const escaped = parseOverride("-- --status-updatable literal title");
    try std.testing.expect(!escaped.status_updatable);
    try std.testing.expectEqualStrings("--status-updatable literal title", escaped.title);
    try std.testing.expectEqualStrings("", parseOverride("").title);
    try std.testing.expectEqualStrings("", parseOverride("--status-updatable ").title);
    try expectTitle("My tab", "My tab", "Working", false);
    try expectTitle("Working My tab", live.title, "Working", live.status_updatable);
}
