//! Local private OSC 77701;ghostty-title-status=<base64 UTF-8> ST.
//! The terminal treats the decoded text as an opaque prefix. Empty clears it.
const std = @import("std");
const encoding = @import("../terminal/osc/encoding.zig");

pub const prefix = "77701;ghostty-title-status=";

pub fn decode(content: []const u8, truncated: bool, out: *[256]u8) ?[:0]const u8 {
    if (truncated or !std.mem.startsWith(u8, content, prefix)) return null;
    const encoded = content[prefix.len..];
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(encoded) catch return null;
    if (len >= out.len) return null;
    decoder.decode(out[0..len], encoded) catch return null;
    if (!encoding.isSafeUtf8(out[0..len])) return null;
    out[len] = 0;
    return out[0..len :0];
}

test "title status: arbitrary text and an explicit clear" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Building; phase 2", decode(prefix ++ "QnVpbGRpbmc7IHBoYXNlIDI=", false, &buf).?);
    try std.testing.expectEqualStrings("", decode(prefix, false, &buf).?);
    try std.testing.expectEqualStrings("\xe2\x97\x90", decode(prefix ++ "4peQ", false, &buf).?);
}

test "title status: malformed and unrelated OSCs do not update status" {
    var buf: [256]u8 = undefined;
    for ([_][]const u8{
        "7400;ghostty-title-status=QQ==", prefix ++ "?",    prefix ++ "QQ=",  prefix ++ "/w==",
        prefix ++ "YQpi",                 prefix ++ "AA==", prefix ++ "wps=", prefix ++ "aW5qZWN0G10=",
    }) |content| try std.testing.expect(decode(content, false, &buf) == null);
    try std.testing.expect(decode(prefix ++ "QQ==", true, &buf) == null);
    const large: [344]u8 = std.simd.repeat(344, "QUFB".*);
    try std.testing.expect(decode(prefix ++ large, false, &buf) == null);
}

test "title status: unknown OSC capture handles fragmentation and both terminators" {
    const terminal = @import("../terminal/main.zig");
    const Handler = struct {
        buf: [256]u8 = undefined,
        status: ?[:0]const u8 = null,

        pub fn vt(self: *@This(), comptime action: terminal.StreamAction.Key, value: terminal.StreamAction.Value(action)) !void {
            if (action == .osc_unknown)
                self.status = decode(value.content, value.truncated, &self.buf);
        }
    };
    for ([_][]const u8{ "\x07", "\x1b\\" }) |terminator| {
        var stream: terminal.Stream(Handler) = .init(.{
            .handler = .{},
            .osc_unknown_max_bytes = 512,
        });
        defer stream.deinit();
        stream.nextSlice("\x1b]77701;ghostty-title-status=QnVp");
        try std.testing.expect(stream.handler.status == null);
        stream.nextSlice("bGRpbmc=");
        stream.nextSlice(terminator);
        try std.testing.expectEqualStrings("Building", stream.handler.status.?);
    }
}
