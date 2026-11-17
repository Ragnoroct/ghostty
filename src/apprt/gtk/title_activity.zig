//! Keep Codex activity visible when a tab or surface has a manual name.
//! Only recognized decorations are copied; the program's title body stays hidden.
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
    terminal: ?[]const u8,
    overridden: bool,
) std.Io.Writer.Error!void {
    if (!overridden) return writer.writeAll(plain);
    const source = terminal orelse return writer.writeAll(plain);

    if (activityPrefix(source)) |prefix| {
        try writer.writeAll(prefix);
        try writer.writeByte(' ');
    }
    try writer.writeAll(plain);
    if (taskProgress(source)) |progress| {
        try writer.writeAll(" | ");
        try writer.writeAll(progress);
    }
}

fn activityPrefix(title: []const u8) ?[]const u8 {
    for ([_][]const u8{
        "[ ! ] Action Required",
        "[ . ] Action Required",
        "[!] Action Required",
        "[.] Action Required",
        // Codex's ten Braille spinner frames, expressed as UTF-8 bytes.
        "\xe2\xa0\x8b",
        "\xe2\xa0\x99",
        "\xe2\xa0\xb9",
        "\xe2\xa0\xb8",
        "\xe2\xa0\xbc",
        "\xe2\xa0\xb4",
        "\xe2\xa0\xa6",
        "\xe2\xa0\xa7",
        "\xe2\xa0\x87",
        "\xe2\xa0\x8f",
    }) |prefix| {
        if (std.mem.startsWith(u8, title, prefix) and
            (title.len == prefix.len or title[prefix.len] == ' ')) return title[0..prefix.len];
    }
    return null;
}

fn taskProgress(title: []const u8) ?[]const u8 {
    var parts = std.mem.splitSequence(u8, title, " | ");
    while (parts.next()) |part| {
        if (!std.mem.startsWith(u8, part, "Tasks ")) continue;
        const counts = part["Tasks ".len..];
        const slash = std.mem.indexOfScalar(u8, counts, '/') orelse continue;
        if (!digits(counts[0..slash]) or !digits(counts[slash + 1 ..])) continue;
        return part;
    }
    return null;
}

fn digits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn expectTitle(expected: []const u8, plain: []const u8, terminal: ?[]const u8, overridden: bool) !void {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try writeTitle(&buf.writer, plain, terminal, overridden);
    try std.testing.expectEqualStrings(expected, buf.written());
}

test "title activity: manual name follows working, attention, progress, and idle transitions" {
    try expectTitle("\xe2\xa0\x8b my tab", "my tab", "\xe2\xa0\x8b Original thread | project", true);
    try expectTitle("\xe2\xa0\xb4 my tab | Tasks 2/5", "my tab", "\xe2\xa0\xb4 Original thread | Tasks 2/5 | project", true);
    try expectTitle("[ ! ] Action Required my tab | Tasks 2/5", "my tab", "[ ! ] Action Required | Tasks 2/5 | project", true);
    try expectTitle("[ . ] Action Required my tab | Tasks 2/5", "my tab", "[ . ] Action Required | Tasks 2/5 | project", true);
    try expectTitle("my tab | Tasks 5/5", "my tab", "Original thread | project | Tasks 5/5", true);
    try expectTitle("my tab", "my tab", "Original thread | project", true);
    try expectTitle("my tab", "my tab", "willy@host: ~/project", true);
}

test "title activity: recognizes all spinner frames and both compact attention phases" {
    for ([_][]const u8{
        "\xe2\xa0\x8b",        "\xe2\xa0\x99",        "\xe2\xa0\xb9", "\xe2\xa0\xb8", "\xe2\xa0\xbc",
        "\xe2\xa0\xb4",        "\xe2\xa0\xa6",        "\xe2\xa0\xa7", "\xe2\xa0\x87", "\xe2\xa0\x8f",
        "[!] Action Required", "[.] Action Required",
    }) |prefix| {
        const terminal = try std.fmt.allocPrint(std.testing.allocator, "{s} | project", .{prefix});
        defer std.testing.allocator.free(terminal);
        const expected = try std.fmt.allocPrint(std.testing.allocator, "{s} custom", .{prefix});
        defer std.testing.allocator.free(expected);
        try expectTitle(expected, "custom", terminal, true);
        try expectTitle(expected, "custom", prefix, true);
    }
}

test "title activity: ordinary and malformed titles do not leak through the override" {
    for ([_][]const u8{
        "[!] build failed",       "[.] notes",                 "[ ! ] Action Requiredness | project",
        "\xe2\xa0\x8bfilename",   "project | Tasks /5",        "project | Tasks 2/",
        "project | Tasks 2/x",    "project | Tasks 2/5 extra", "project | Tasks 2/5/6",
        "project | My Tasks 2/5", "project | Tasks -1/5",      "",
    }) |terminal| try expectTitle("custom", "custom", terminal, true);
    try expectTitle("custom", "custom", null, true);
}

test "title activity: automatic titles and cleared overrides stay unchanged" {
    const title = "[ ! ] Action Required | project | Tasks 2/5";
    try expectTitle(title, title, title, false);
    try expectTitle("Ghostty", "Ghostty", null, false);
    try expectTitle("renamed", "renamed", "original | project", true);
}

test "title activity: readonly and status-updatable flags keep existing titles compatible" {
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
    const source = "[ ! ] Action Required | project | Tasks 2/5";
    try expectTitle("My tab", "My tab", source, false);
    try expectTitle("[ ! ] Action Required My tab | Tasks 2/5", live.title, source, live.status_updatable);
}
