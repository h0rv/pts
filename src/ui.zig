const std = @import("std");
const model = @import("model.zig");
const http = @import("http.zig");
const parser = @import("parser.zig");
const cache = @import("cache.zig");

const Allocator = std.mem.Allocator;

const RawMode = struct {
    active: bool = false,
    original: if (@import("builtin").os.tag == .linux) std.posix.termios else void = if (@import("builtin").os.tag == .linux) undefined else {},

    fn init() RawMode {
        if (@import("builtin").os.tag != .linux) return .{};
        var self: RawMode = .{};
        self.original = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return .{};
        var raw = self.original;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw) catch return .{};
        self.active = true;
        return self;
    }

    fn deinit(self: *RawMode) void {
        if (@import("builtin").os.tag != .linux) return;
        if (self.active) std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.original) catch {};
    }
};

const App = struct {
    allocator: Allocator,
    io: std.Io,
    client: *std.http.Client,
    cache_root: []u8,
    current_url: []u8,
    history: std.ArrayList([]u8) = .empty,
    page: ?model.ParsedPage = null,
    selected: usize = 0,
    scroll: usize = 0,
    filter: []u8,
    auto_refresh: bool = true,
    refresh_interval_ms: u64,
    last_refresh_ms: ?i64 = null,
    last_error: ?[]u8 = null,
    cached: bool = false,
    help: bool = false,
    use_cache: bool,
    debug: bool,

    fn init(allocator: Allocator, io: std.Io, client: *std.http.Client, cache_root: []const u8, url: []const u8, refresh_seconds: u64, use_cache: bool, debug: bool) !App {
        return .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .cache_root = try allocator.dupe(u8, cache_root),
            .current_url = try allocator.dupe(u8, url),
            .filter = try allocator.dupe(u8, ""),
            .refresh_interval_ms = refresh_seconds * 1000,
            .use_cache = use_cache,
            .debug = debug,
        };
    }

    fn deinit(self: *App) void {
        self.allocator.free(self.cache_root);
        self.allocator.free(self.current_url);
        for (self.history.items) |url| self.allocator.free(url);
        self.history.deinit(self.allocator);
        if (self.page) |page| page.deinit(self.allocator);
        self.allocator.free(self.filter);
        if (self.last_error) |err| self.allocator.free(err);
    }

    fn setError(self: *App, comptime fmt: []const u8, args: anytype) void {
        if (self.last_error) |err| self.allocator.free(err);
        self.last_error = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
    }

    fn clearError(self: *App) void {
        if (self.last_error) |err| self.allocator.free(err);
        self.last_error = null;
    }

    fn load(self: *App) void {
        const body = http.fetchPage(self.allocator, self.client, self.current_url) catch |err| {
            self.cached = false;
            if (self.debug) std.debug.print("fetch error {s}: {any}\n", .{ self.current_url, err });
            if (self.use_cache) {
                if (cache.read(self.io, self.allocator, self.cache_root, self.current_url) catch null) |cached_body| {
                    self.installBody(cached_body, true) catch |parse_err| {
                        self.allocator.free(cached_body);
                        self.setError("Parser error on cached page: {any}", .{parse_err});
                    };
                    self.setError("Network error: {any}; showing cached page", .{err});
                    return;
                }
            }
            self.setError("Network error: failed to fetch {s} ({any})", .{ self.current_url, err });
            return;
        };
        if (self.use_cache) cache.write(self.io, self.allocator, self.cache_root, self.current_url, body) catch |err| if (self.debug) std.debug.print("cache write error: {any}\n", .{err});
        self.installBody(body, false) catch |err| self.setError("Parser error: {any}", .{err});
    }

    fn installBody(self: *App, body: []u8, from_cache: bool) !void {
        defer self.allocator.free(body);
        var parsed = try parser.parsePage(self.allocator, self.current_url, body);
        errdefer parsed.deinit(self.allocator);
        if (self.page) |old| old.deinit(self.allocator);
        self.page = parsed;
        self.cached = from_cache;
        self.last_refresh_ms = nowMs(self.io);
        self.clearError();
        self.clampSelected();
    }

    fn clampSelected(self: *App) void {
        const count = self.filteredCount();
        if (count == 0) self.selected = 0 else if (self.selected >= count) self.selected = count - 1;
        if (self.scroll > self.selected) self.scroll = self.selected;
    }

    fn filteredCount(self: *App) usize {
        const page = self.page orelse return 0;
        if (page.games.len == 0) return 0;
        var n: usize = 0;
        for (page.games) |game| {
            if (self.matchesFilter(game)) n += 1;
        }
        return n;
    }

    fn gameAtFiltered(self: *App, selected: usize) ?model.Game {
        const page = self.page orelse return null;
        var n: usize = 0;
        for (page.games) |game| {
            if (!self.matchesFilter(game)) continue;
            if (n == selected) return game;
            n += 1;
        }
        return null;
    }

    fn matchesFilter(self: *App, game: model.Game) bool {
        if (self.filter.len == 0) return true;
        return containsIgnoreCase(game.title, self.filter) or containsIgnoreCase(game.status_text, self.filter) or containsIgnoreCase(game.league_name, self.filter);
    }

    fn openSelected(self: *App) void {
        const game = self.gameAtFiltered(self.selected) orelse return;
        const url = game.url orelse return;
        const old = self.allocator.dupe(u8, self.current_url) catch return;
        self.history.append(self.allocator, old) catch {
            self.allocator.free(old);
            return;
        };
        self.allocator.free(self.current_url);
        self.current_url = self.allocator.dupe(u8, url) catch return;
        self.selected = 0;
        self.scroll = 0;
        self.load();
    }

    fn back(self: *App) void {
        if (self.help) {
            self.help = false;
            return;
        }
        if (self.history.items.len == 0) return;
        self.allocator.free(self.current_url);
        self.current_url = self.history.pop().?;
        self.selected = 0;
        self.scroll = 0;
        self.load();
    }

    fn setFilter(self: *App, value: []const u8) void {
        self.allocator.free(self.filter);
        self.filter = self.allocator.dupe(u8, value) catch self.allocator.dupe(u8, "") catch unreachable;
        self.selected = 0;
        self.scroll = 0;
        self.clampSelected();
    }
};

pub fn run(allocator: Allocator, io: std.Io, client: *std.http.Client, cache_root: []const u8, url: []const u8, refresh_seconds: u64, use_cache: bool, debug: bool) !void {
    var app = try App.init(allocator, io, client, cache_root, url, refresh_seconds, use_cache, debug);
    defer app.deinit();
    app.load();

    var raw = RawMode.init();
    defer raw.deinit();
    try writeStdout(io, "\x1b[?1049h\x1b[?25l\x1b[2J");
    defer writeStdout(io, "\x1b[?25h\x1b[0m\x1b[?1049l") catch {};

    var running = true;
    while (running) {
        try render(&app);
        const timeout = timeoutFor(&app);
        const key = readKey(app.io, timeout) catch .none;
        switch (key) {
            .none => if (shouldAutoRefresh(&app)) app.load(),
            .quit => running = false,
            .down => moveDown(&app, 1),
            .up => moveUp(&app, 1),
            .page_down => moveDown(&app, visibleBodyRows()),
            .page_up => moveUp(&app, visibleBodyRows()),
            .top => {
                app.selected = 0;
                app.scroll = 0;
            },
            .bottom => {
                const count = app.filteredCount();
                if (count > 0) app.selected = count - 1 else app.scroll = maxRawScroll(&app);
            },
            .enter => app.openSelected(),
            .back => app.back(),
            .refresh => app.load(),
            .auto => app.auto_refresh = !app.auto_refresh,
            .help => app.help = !app.help,
            .filter => {
                const q = try promptFilter(app.io, allocator, app.filter);
                defer allocator.free(q);
                app.setFilter(q);
            },
        }
    }
}

const Key = enum { none, quit, down, up, page_down, page_up, top, bottom, enter, back, refresh, auto, help, filter };

fn readKey(io: std.Io, timeout_ms: i32) !Key {
    if (!try inputReady(timeout_ms)) return .none;
    const first = try readByte(io);
    return switch (first) {
        'q' => .quit,
        'j' => .down,
        'k' => .up,
        'd', ' ' => .page_down,
        'u' => .page_up,
        'g' => .top,
        'G' => .bottom,
        '\r', '\n' => .enter,
        'b' => .back,
        27 => try readEscapeKey(io),
        'r' => .refresh,
        'a' => .auto,
        '?' => .help,
        '/' => .filter,
        else => .none,
    };
}

fn inputReady(timeout_ms: i32) !bool {
    if (@import("builtin").os.tag == .windows) return true;
    var fds = [_]std.posix.pollfd{.{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&fds, timeout_ms) != 0;
}

fn readByte(io: std.Io) !u8 {
    var b: [1]u8 = undefined;
    while (true) {
        const n = try std.Io.File.stdin().readStreaming(io, &.{&b});
        if (n != 0) return b[0];
    }
}

fn readEscapeKey(io: std.Io) !Key {
    if (!try inputReady(0)) return .back;
    const b1 = try readByte(io);
    if (b1 != '[') return .back;
    if (!try inputReady(0)) return .back;
    const b2 = try readByte(io);
    return switch (b2) {
        'A' => .up,
        'B' => .down,
        '5' => blk: {
            if (try inputReady(0)) _ = try readByte(io);
            break :blk .page_up;
        },
        '6' => blk: {
            if (try inputReady(0)) _ = try readByte(io);
            break :blk .page_down;
        },
        else => .back,
    };
}

fn ensureSelectedVisible(app: *App, body_rows: usize) void {
    const visible_games = if (body_rows > 1) body_rows - 1 else 1;
    if (app.selected < app.scroll) app.scroll = app.selected;
    if (app.selected >= app.scroll + visible_games) app.scroll = app.selected - visible_games + 1;
}

fn moveDown(app: *App, amount: usize) void {
    const count = app.filteredCount();
    if (count > 0) {
        app.selected = @min(count - 1, app.selected + amount);
    } else {
        app.scroll = @min(maxRawScroll(app), app.scroll + amount);
    }
}

fn moveUp(app: *App, amount: usize) void {
    const count = app.filteredCount();
    if (count > 0) {
        app.selected = if (app.selected > amount) app.selected - amount else 0;
    } else {
        app.scroll = if (app.scroll > amount) app.scroll - amount else 0;
    }
}

fn visibleBodyRows() usize {
    const rows = terminalRows();
    return if (rows > 8) rows - 8 else 6;
}

fn maxRawScroll(app: *const App) usize {
    const p = app.page orelse return 0;
    if (p.games.len > 0) return 0;
    const count = rawRenderableLineCount(p.visible_text);
    const visible = visibleBodyRows();
    return if (count > visible) count - visible else 0;
}

fn rawRenderableLineCount(text: []const u8) usize {
    var n: usize = 0;
    var started = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "Page loaded:") or std.mem.startsWith(u8, trimmed, "Data loaded:")) continue;
        if (!started and trimmed.len == 0) continue;
        started = true;
        n += 1;
    }
    return n;
}

fn timeoutFor(app: *const App) i32 {
    if (!app.auto_refresh) return 1000;
    const last = app.last_refresh_ms orelse return 0;
    const now = nowMs(app.io);
    const due = last + @as(i64, @intCast(app.refresh_interval_ms));
    if (now >= due) return 0;
    const delta = due - now;
    if (delta > 1000) return 1000;
    return @intCast(delta);
}

fn shouldAutoRefresh(app: *const App) bool {
    if (!app.auto_refresh) return false;
    const last = app.last_refresh_ms orelse return true;
    return nowMs(app.io) - last >= @as(i64, @intCast(app.refresh_interval_ms));
}

fn render(app: *App) !void {
    var aw = std.Io.Writer.Allocating.init(app.allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("\x1b[H");

    if (app.help) {
        try w.writeAll(
            \\Plain Text Sports - Help
            \\
            \\j/down     Move down
            \\k/up       Move up
            \\enter      Open selected item
            \\b/esc      Back
            \\r          Refresh
            \\a          Toggle auto-refresh
            \\/          Filter
            \\d/u        Page down/up
            \\g/G        Top/bottom
            \\q          Quit
            \\
            \\Press ? or b to close.
            \\
        );
        try writeStdout(app.io, aw.written());
        return;
    }

    const rows = terminalRows();
    const page = app.page;
    if (page) |p| {
        try w.print("{s}\n{s}\n", .{ p.title, app.current_url });
        try renderMetaLine(w, app, p);
        if (app.last_error) |err| try w.print("ERROR: {s}\n", .{err});
        try w.writeAll("\n");
        const used_before_body: usize = 5 + if (app.last_error != null) @as(usize, 1) else 0;
        const footer_lines: usize = 2;
        const body_budget = if (rows > used_before_body + footer_lines) rows - used_before_body - footer_lines else 6;
        if (p.games.len > 0) {
            ensureSelectedVisible(app, body_budget);
            try renderGames(w, app, p, body_budget);
        } else {
            if (p.kind != .game) try w.writeAll("Could not parse structured games. Showing raw page text.\n");
            if (app.scroll > 0) try w.print("↑ {d} lines\n", .{app.scroll});
            try renderRawText(w, p.visible_text, app.scroll, body_budget);
        }
    } else {
        try w.writeAll("Plain Text Sports\nNo page loaded. Press r to retry.\n");
    }

    try w.writeAll("\n");
    if (app.filter.len > 0) try w.print("filter:{s} · ", .{app.filter});
    try w.print("keys: j/k move · d/u page · enter open · r refresh · / filter · ? help · q quit\n", .{});

    try w.writeAll("\x1b[J");
    try writeStdout(app.io, aw.written());
}

fn renderMetaLine(w: *std.Io.Writer, app: *App, page: model.ParsedPage) !void {
    if (page.data_loaded_at_text) |data| try w.print("data: {s}", .{cleanLoaded(data)}) else try w.writeAll("data: n/a");
    if (app.last_refresh_ms) |ms| {
        const age_ms = nowMs(app.io) - ms;
        try w.print(" · refreshed: {d}s ago", .{if (age_ms > 0) @divTrunc(age_ms, 1000) else 0});
    }
    try w.print(" · auto: {s}/{d}s", .{ if (app.auto_refresh) "on" else "off", app.refresh_interval_ms / 1000 });
    if (app.cached) try w.writeAll(" · offline cache");
    try w.writeAll("\n");
}

fn cleanLoaded(line: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, line, ':')) |idx| return std.mem.trim(u8, line[idx + 1 ..], " \t\r");
    return std.mem.trim(u8, line, " \t\r");
}

fn renderGames(w: *std.Io.Writer, app: *App, page: model.ParsedPage, max_lines: usize) !void {
    var filtered_index: usize = 0;
    var any_live = false;
    for (page.games) |game| {
        if (game.status == .live and app.matchesFilter(game)) any_live = true;
    }
    var lines: usize = 0;
    if (any_live) try w.writeAll("LIVE") else try w.writeAll("GAMES");
    if (app.scroll > 0) try w.print(" (↑{d})", .{app.scroll});
    try w.writeByte('\n');
    lines += 1;
    for (page.games) |game| {
        if (!app.matchesFilter(game)) continue;
        if (filtered_index < app.scroll) {
            filtered_index += 1;
            continue;
        }
        if (lines >= max_lines) {
            try w.writeAll("...\n");
            return;
        }
        const selected = filtered_index == app.selected;
        const prefix = if (selected) "> " else "  ";
        const status_mark = switch (game.status) {
            .live => "LIVE",
            .upcoming => "UP",
            .final => "FINAL",
            .postponed => "PPD",
            .unknown => "",
        };
        const league = if (game.sport == .unknown) "" else game.league_name;
        try w.print("{s}{s:<6} {s:<5} {s:<9} {s}", .{ prefix, league, status_mark, game.title, game.status_text });
        if (game.network) |n| try w.print(" · {s}", .{n});
        try w.writeAll("\n");
        filtered_index += 1;
        lines += 1;
    }
    if (filtered_index == 0) try w.writeAll("No games match filter. Press / to change.\n");
}

fn renderRawText(w: *std.Io.Writer, text: []const u8, scroll: usize, max_lines: usize) !void {
    var lines: usize = 0;
    var skipped: usize = 0;
    var started = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "Page loaded:") or std.mem.startsWith(u8, trimmed, "Data loaded:")) continue;
        if (!started and trimmed.len == 0) continue;
        started = true;
        if (skipped < scroll) {
            skipped += 1;
            continue;
        }
        if (lines >= max_lines) {
            try w.writeAll("...\n");
            return;
        }
        try w.print("{s}\n", .{line});
        lines += 1;
    }
}

fn promptFilter(io: std.Io, allocator: Allocator, old: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try out.writer.print("\x1b[?25h\nfilter [{s}]: ", .{old});
    try writeStdout(io, out.written());

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    while (true) {
        var b: [1]u8 = undefined;
        const n = try std.Io.File.stdin().readStreaming(io, &.{&b});
        if (n == 0) continue;
        if (b[0] == '\r' or b[0] == '\n') break;
        if (b[0] == 27) break;
        if (b[0] == 127 or b[0] == 8) {
            if (list.items.len > 0) list.shrinkRetainingCapacity(list.items.len - 1);
            continue;
        }
        try list.append(allocator, b[0]);
    }
    if (list.items.len == 0) return allocator.dupe(u8, "");
    return list.toOwnedSlice(allocator);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn terminalRows() usize {
    if (@import("builtin").os.tag == .linux) {
        var ws: std.posix.winsize = undefined;
        const rc = std.os.linux.ioctl(std.posix.STDOUT_FILENO, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == 0 and ws.row > 0) return ws.row;
    }
    return 24;
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}
