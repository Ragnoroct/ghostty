//! Main-thread GTK adapter for persistent window snapshots.
const std = @import("std");
const global = @import("../../global.zig");
const gtk = @import("gtk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const primitive = @import("window_state.zig");
const Window = @import("class/window.zig").Window;
const Tab = @import("class/tab.zig").Tab;
const Surface = @import("class/surface.zig").Surface;
const Application = @import("class/application.zig").Application;
const log = std.log.scoped(.window_state);

pub const State = struct {
    enabled: bool = false,
    closing: bool = false,
    timer: ?c_uint = null,
    created: i64 = 0,
    last_input_wall_ms: i64 = 0,
    scheduler: primitive.Scheduler = .{},
    hash: ?u64 = null,

    pub fn init(self: *State, window: *Window) void {
        const created = self.created;
        const active = self.last_input_wall_ms;
        self.dispose();
        self.* = .{ .created = created, .last_input_wall_ms = active };
        const cfg = window.getConfig() orelse return;
        self.enabled = cfg.get().@"window-state-export";
        if (!self.enabled) return;
        gc() catch |err| log.warn("state GC failed: {t}", .{err});
        if (self.created == 0) self.created = @divTrunc(glib.getRealTime(), 1000);
        if (self.last_input_wall_ms == 0) self.last_input_wall_ms = self.created;
        self.scheduler.structural(mono());
        // A single low-frequency sampler bounds heartbeat latency without
        // allocating, arming or cancelling timers in the per-input path.
        self.timer = glib.timeoutAdd(200, tick, window);
    }
    pub fn dispose(self: *State) void {
        if (self.timer) |t| _ = glib.Source.remove(t);
        self.timer = null;
        self.enabled = false;
    }
    pub fn structural(self: *State) void {
        if (!self.enabled or self.closing) return;
        self.scheduler.structural(mono());
    }
    pub fn soft(self: *State) void {
        if (self.enabled and !self.closing) self.scheduler.soft = true;
    }
    pub fn input(self: *State) void {
        if (!self.enabled or self.closing) return;
        // GLib uses the Linux vDSO clock; no allocation or timer operations.
        self.last_input_wall_ms = @divTrunc(glib.getRealTime(), 1000);
        self.scheduler.input = self.last_input_wall_ms;
    }
    pub fn close(self: *State, window: *Window, reason: []const u8) void {
        if (!self.enabled or self.closing) return;
        self.closing = true;
        write(window, self, true, reason) catch |err| log.warn("final snapshot failed: {t}", .{err});
        self.dispose();
    }
};
fn mono() i64 {
    return @divTrunc(glib.getMonotonicTime(), 1000);
}
fn tick(data: ?*anyopaque) callconv(.c) c_int {
    const window: *Window = @ptrCast(@alignCast(data orelse return 0));
    const state = window.getSnapshotState();
    if (!state.enabled or state.closing) return 0;
    gc() catch |err| log.warn("state GC failed: {t}", .{err});
    const now = mono();
    const due = state.scheduler.due(now);
    if (due.any()) {
        write(window, state, due.structural or due.soft, null) catch |err| {
            log.warn("snapshot failed: {t}", .{err});
            // Rate-limit retries as well as successful writes.
        };
        state.scheduler.flushed(now, due);
    }
    return 1;
}

const Node = union(enum) {
    leaf: struct {
        surface_id: []const u8,
        pwd: ?[]const u8,
        title: ?[]const u8,
        shell_pid: ?i32,
        focused: bool,
    },
    split: struct { layout: []const u8, ratio: f32, left: *Node, right: *Node },
    pub fn jsonStringify(self: Node, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("type");
        try writer.write(@tagName(self));
        switch (self) {
            inline else => |v| inline for (@typeInfo(@TypeOf(v)).@"struct".field_names) |field| {
                try writer.objectField(field);
                try writer.write(@field(v, field));
            },
        }
        try writer.endObject();
    }
};
fn node(alloc: std.mem.Allocator, tree: *const Surface.Tree, index: Surface.Tree.Node.Handle) !*Node {
    const result = try alloc.create(Node);
    result.* = switch (tree.nodes[index.idx()]) {
        .leaf => |surface| .{ .leaf = .{
            .surface_id = surface.getStateId(),
            .pwd = surface.getPwd(),
            .title = surface.getTitle(),
            .shell_pid = surface.getShellPid(),
            .focused = surface.getFocused(),
        } },
        // Horizontal divides width into left/right; vertical divides height
        // into top/bottom. Ratio is the fraction assigned to the left (first)
        // child, which is the top child for a vertical split.
        .split => |s| .{ .split = .{
            .layout = @tagName(s.layout),
            .ratio = @floatCast(s.ratio),
            .left = try node(alloc, tree, s.left),
            .right = try node(alloc, tree, s.right),
        } },
    };
    return result;
}
const TabData = struct {
    id: []const u8,
    title: ?[]const u8,
    tree: ?*Node,
    zoomed_surface_id: ?[]const u8,
};

fn directory(alloc: std.mem.Allocator, app_id: []const u8) !std.Io.Dir {
    const env = global.environ().getPosix("XDG_STATE_HOME");
    const base = if (env) |v| if (std.fs.path.isAbsolute(v)) v else null else null;
    const path = if (base) |v| v else try std.fmt.allocPrint(alloc, "{s}/.local/state", .{global.environ().getPosix("HOME") orelse return error.NoHome});
    try std.Io.Dir.cwd().createDirPath(global.io(), path);
    var parent = try std.Io.Dir.cwd().openDir(global.io(), path, .{});
    defer parent.close(global.io());
    for ([_][]const u8{ "ghostty", app_id, "windows" }) |part| {
        parent.createDir(global.io(), part, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const child = try parent.openDir(global.io(), part, .{ .iterate = true, .follow_symlinks = false });
        parent.close(global.io());
        parent = child;
        try parent.setPermissions(global.io(), .fromMode(0o700));
    }
    return parent.openDir(global.io(), ".", .{ .iterate = true });
}

fn write(window: *Window, state: *State, sync: bool, reason: ?[]const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const app_id = std.mem.span(Application.default().as(gio.Application).getApplicationId() orelse return error.NoAppId);
    const view = window.getTabView();
    const tabs = try alloc.alloc(TabData, @intCast(view.getNPages()));
    var selected: ?[]const u8 = null;
    for (tabs, 0..) |*t, i| {
        const page = view.getNthPage(@intCast(i));
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return error.NotTab;
        if (view.getSelectedPage() == page) selected = tab.getStateId();
        const tree = tab.getSurfaceTree();
        t.* = .{
            .id = tab.getStateId(),
            .title = std.mem.span(page.getTitle()),
            .tree = if (tree) |v| if (v.nodes.len != 0) try node(alloc, v, .root) else null else null,
            .zoomed_surface_id = if (tree) |v| if (v.zoomed) |z| switch (v.nodes[z.idx()]) {
                .leaf => |s| s.getStateId(),
                else => null,
            } else null else null,
        };
    }
    const now = @divTrunc(glib.getRealTime(), 1000);
    const created = primitive.timestamp(state.created);
    const updated = primitive.timestamp(now);
    const active = primitive.timestamp(state.last_input_wall_ms);
    const boot_raw = try readBootId(alloc);
    const pid: i32 = @intCast(std.os.linux.getpid());
    const Snapshot = struct {
        version: u32,
        window_id: []const u8,
        app_id: []const u8,
        pid: i32,
        pid_start_ticks: u64,
        boot_id: []const u8,
        created_at: []const u8,
        updated_at: []const u8,
        last_active_at: []const u8,
        closed_at_best_effort: ?[]const u8,
        closed_reason_best_effort: ?[]const u8,
        width: c_int,
        height: c_int,
        maximized: bool,
        selected_tab_id: ?[]const u8,
        tabs: []TabData,
    };
    var payload: Snapshot = .{
        .version = @as(u32, 1),
        .window_id = @as([]const u8, window.getStateId()),
        .app_id = app_id,
        .pid = pid,
        .pid_start_ticks = try primitive.processTicks(alloc, pid),
        .boot_id = std.mem.trim(u8, boot_raw, "\r\n "),
        .created_at = @as([]const u8, &created),
        .updated_at = @as([]const u8, ""),
        .last_active_at = @as([]const u8, &active),
        .closed_at_best_effort = @as(?[]const u8, if (reason != null) &updated else null),
        .closed_reason_best_effort = reason,
        .width = window.as(gtk.Widget).getWidth(),
        .height = window.as(gtk.Widget).getHeight(),
        .maximized = window.as(gtk.Window).isMaximized() != 0,
        .selected_tab_id = selected,
        .tabs = tabs,
    };
    const comparable = try std.json.Stringify.valueAlloc(alloc, payload, .{});
    const hash = std.hash.Wyhash.hash(0, comparable);
    if (state.hash == hash) return;
    payload.updated_at = &updated;
    const bytes = try std.json.Stringify.valueAlloc(alloc, payload, .{});
    var dir = try directory(alloc, app_id);
    defer dir.close(global.io());
    const target = try std.fmt.allocPrint(alloc, "{s}.json", .{window.getStateId()});
    const temp = try std.fmt.allocPrint(alloc, ".{s}.{x}.tmp", .{ window.getStateId(), randomU64() });
    const file = try dir.createFile(global.io(), temp, .{ .permissions = .fromMode(0o600), .exclusive = true });
    defer file.close(global.io());
    defer dir.deleteFile(global.io(), temp) catch {};
    try file.writeStreamingAll(global.io(), bytes);
    if (sync) try file.sync(global.io());
    try dir.rename(temp, dir, target, global.io());
    state.hash = hash;
}

var gc_last: ?i64 = null;
pub fn gc() !void {
    const now_mono = mono();
    if (gc_last) |last| if (now_mono - last < 86_400_000) return;
    gc_last = now_mono;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const app_id = std.mem.span(Application.default().as(gio.Application).getApplicationId() orelse return);
    var dir = try directory(alloc, app_id);
    defer dir.close(global.io());
    const boot_raw = try readBootId(alloc);
    const boot = std.mem.trim(u8, boot_raw, "\r\n ");
    const now = @divTrunc(glib.getRealTime(), 1000);
    const closed_before = primitive.timestamp(now - primitive.closed_days * 86_400_000);
    const idle_before = primitive.timestamp(now - primitive.idle_days * 86_400_000);
    var it = dir.iterate();
    var warned = false;
    while (try it.next(global.io())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const remove = gcFile(alloc, dir, entry.name, boot, &closed_before, &idle_before) catch |err| {
            if (!warned) log.warn("ignoring unreadable window state: {t}", .{err});
            warned = true;
            continue;
        };
        if (remove) dir.deleteFile(global.io(), entry.name) catch |err| log.warn("state GC delete failed: {t}", .{err});
    }
}
fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidState;
    const v = value.object.get(name) orelse return error.InvalidState;
    return if (v == .string) v.string else error.InvalidState;
}
fn integerField(value: std.json.Value, name: []const u8) !i64 {
    if (value != .object) return error.InvalidState;
    const v = value.object.get(name) orelse return error.InvalidState;
    return if (v == .integer) v.integer else error.InvalidState;
}
fn validTimestamp(s: []const u8) bool {
    if (s.len != 24) return false;
    for (s, 0..) |c, i| switch (i) {
        4, 7 => if (c != '-') return false,
        10 => if (c != 'T') return false,
        13, 16 => if (c != ':') return false,
        19 => if (c != '.') return false,
        23 => if (c != 'Z') return false,
        else => if (!std.ascii.isDigit(c)) return false,
    };
    return true;
}
fn gcFile(alloc: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, boot: []const u8, closed_before: []const u8, idle_before: []const u8) !bool {
    const raw = try dir.readFileAlloc(global.io(), name, alloc, .limited(1024 * 1024));
    defer alloc.free(raw);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const v = parsed.value;
    if (try integerField(v, "version") != 1) return error.UnknownVersion;
    const pid = std.math.cast(i32, try integerField(v, "pid")) orelse return error.InvalidPid;
    if (pid <= 0) return error.InvalidPid;
    const ticks = std.math.cast(u64, try integerField(v, "pid_start_ticks")) orelse return error.InvalidTicks;
    const file_boot = try stringField(v, "boot_id");
    if (std.mem.eql(u8, boot, file_boot)) {
        const current = primitive.processTicks(alloc, pid) catch |err| switch (err) {
            error.FileNotFound => 0,
            else => return err, // Fail closed on inaccessible /proc records.
        };
        if (current == ticks and ticks != 0) return false;
    }
    const active = stringField(v, "last_active_at") catch try stringField(v, "updated_at");
    if (!validTimestamp(active)) return error.InvalidTimestamp;
    const closed = v.object.get("closed_at_best_effort") orelse return error.InvalidState;
    if (closed != .null) {
        if (closed != .string or !validTimestamp(closed.string)) return error.InvalidTimestamp;
        if (std.mem.order(u8, closed.string, closed_before) == .lt) return true;
    }
    return std.mem.order(u8, active, idle_before) == .lt;
}

test "window state: leaf JSON golden" {
    const leaf: Node = .{ .leaf = .{
        .surface_id = "abc",
        .pwd = null,
        .title = "a\"b",
        .shell_pid = 42,
        .focused = true,
    } };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, leaf, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"type\":\"leaf\",\"surface_id\":\"abc\",\"pwd\":null,\"title\":\"a\\\"b\",\"shell_pid\":42,\"focused\":true}", json);
}

fn randomU64() u64 {
    var value: u64 = undefined;
    global.io().random(std.mem.asBytes(&value));
    return value;
}

fn readBootId(alloc: std.mem.Allocator) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(global.io(), "/proc/sys/kernel/random/boot_id", .{});
    defer file.close(global.io());
    return @import("../../lib/compat/file.zig").readToEndAlloc(file, alloc, 128);
}
