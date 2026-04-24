const std = @import("std");
const model = @import("model.zig");
const http = @import("http.zig");
const parser = @import("parser.zig");
const cache = @import("cache.zig");

const Allocator = std.mem.Allocator;

const fallback_terminal_rows: usize = 24;
const fallback_terminal_cols: usize = 80;
const min_body_rows: usize = 6;
const footer_rows: usize = 1;
const no_error_rows: usize = 0;
const error_rows: usize = 2;
const game_list_header_rows: usize = 1;
const min_visible_games: usize = 1;
const single_row_step: usize = 1;
const line_count_initial: usize = 1;
const ms_per_second: u64 = 1000;
const ms_per_second_i64: i64 = 1000;
const poll_tick_ms: i32 = 1000;
const escape_key: u8 = 27;
const delete_key: u8 = 127;
const backspace_key: u8 = 8;
const footer_gap_cols: usize = 3;
const footer_meta_buf_len: usize = 64;
const league_col_width: usize = 6;
const status_col_width: usize = 5;
const matchup_col_width: usize = 9;
const event_col_width: usize = 4;
const time_col_width: usize = 11;

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
            .refresh_interval_ms = refresh_seconds * ms_per_second,
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

    fn activeUrl(self: *App) []const u8 {
        if (self.gameAtFiltered(self.selected)) |game| {
            if (game.url) |url| return url;
        }
        return self.current_url;
    }

    fn openBrowser(self: *App) void {
        openUrl(self.io, self.activeUrl()) catch |err| {
            self.setError("open browser failed: {any}", .{err});
        };
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
            .down => moveDown(&app, single_row_step),
            .up => moveUp(&app, single_row_step),
            .page_down => moveDown(&app, currentBodyRows(&app)),
            .page_up => moveUp(&app, currentBodyRows(&app)),
            .top => {
                app.selected = 0;
                app.scroll = 0;
            },
            .bottom => {
                const count = app.filteredCount();
                if (count > 0) app.selected = count - single_row_step else app.scroll = maxRawScroll(&app);
            },
            .enter => app.openSelected(),
            .back => app.back(),
            .refresh => app.load(),
            .open_browser => app.openBrowser(),
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

const Key = enum { none, quit, down, up, page_down, page_up, top, bottom, enter, back, refresh, open_browser, auto, help, filter };

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
        escape_key => try readEscapeKey(io),
        'r' => .refresh,
        'o' => .open_browser,
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
    const visible_games = if (body_rows > game_list_header_rows) body_rows - game_list_header_rows else min_visible_games;
    if (app.selected < app.scroll) app.scroll = app.selected;
    if (app.selected >= app.scroll + visible_games) app.scroll = app.selected - visible_games + 1;
}

fn moveDown(app: *App, amount: usize) void {
    const count = app.filteredCount();
    if (count > 0) {
        app.selected = @min(count - single_row_step, app.selected + amount);
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

fn currentBodyRows(app: *const App) usize {
    return bodyRows(terminalRows(), app.last_error != null);
}

fn bodyRows(rows: usize, has_error: bool) usize {
    const reserved = footer_rows + if (has_error) error_rows else no_error_rows;
    return if (rows > reserved + min_body_rows) rows - reserved else min_body_rows;
}

fn maxRawScroll(app: *const App) usize {
    const p = app.page orelse return 0;
    if (p.games.len > 0) return 0;
    const count = rawRenderableLineCount(p.visible_text);
    const visible = currentBodyRows(app);
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
    if (!app.auto_refresh) return poll_tick_ms;
    const last = app.last_refresh_ms orelse return 0;
    const now = nowMs(app.io);
    const due = last + @as(i64, @intCast(app.refresh_interval_ms));
    if (now >= due) return 0;
    const delta = due - now;
    if (delta > poll_tick_ms) return poll_tick_ms;
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
            \\o          Open in browser
            \\a          Toggle auto-refresh
            \\/          Filter
            \\d/u        Page down/up
            \\g/G        Top/bottom
            \\q          Quit
            \\
            \\Press ? or b to close.
            \\
        );
        try writeFrame(app.io, aw.written());
        return;
    }

    const rows = terminalRows();
    const page = app.page;
    if (page) |p| {
        if (app.last_error) |err| try w.print("ERROR: {s}\n\n", .{err});
        const body_budget = bodyRows(rows, app.last_error != null);
        if (p.games.len > 0) {
            ensureSelectedVisible(app, body_budget);
            try renderGames(w, app, p, body_budget);
        } else {
            if (p.kind == .game) try w.print("{s}\n\n", .{p.title}) else try w.writeAll("Could not parse structured games. Showing raw page text.\n");
            if (app.scroll > 0) try w.print("↑ {d} lines\n", .{app.scroll});
            try renderRawText(w, p.visible_text, app.scroll, body_budget);
        }
    } else {
        try w.writeAll("Plain Text Sports\nNo page loaded. Press r to retry.\n");
    }

    try padToFooter(w, aw.written(), rows);
    try renderFooter(w, app, terminalCols());

    try writeFrame(app.io, aw.written());
}

fn padToFooter(w: *std.Io.Writer, bytes: []const u8, rows: usize) !void {
    const used = renderedLines(bytes);
    if (used >= rows) return;
    var n = rows - used - footer_rows;
    while (n > 0) : (n -= 1) try w.writeByte('\n');
}

fn renderedLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var lines: usize = line_count_initial;
    for (bytes) |b| {
        if (b == '\n') lines += 1;
    }
    return lines;
}

fn renderFooter(w: *std.Io.Writer, app: *App, cols: usize) !void {
    var meta_buf: [footer_meta_buf_len]u8 = undefined;
    var meta_writer = std.Io.Writer.fixed(&meta_buf);
    if (app.last_refresh_ms) |ms| {
        const age_ms = nowMs(app.io) - ms;
        try meta_writer.print("r:{d}s", .{if (age_ms > 0) @divTrunc(age_ms, ms_per_second_i64) else 0});
    } else {
        try meta_writer.writeAll("r:-");
    }
    try meta_writer.print(" auto:{s}/{d}s", .{ if (app.auto_refresh) "on" else "off", app.refresh_interval_ms / ms_per_second });
    if (app.cached) try meta_writer.writeAll(" cache");
    const meta = meta_writer.buffered();

    const long_keys = if (app.filter.len > 0)
        "j/k move · d/u page · enter open · o browser · r refresh · / filter · ? help · q quit"
    else
        "j/k move · d/u page · enter open · o browser · / filter · ? help · q quit";
    const short_keys = "? help · q quit";
    const keys = if (cols >= long_keys.len + meta.len + footer_gap_cols) long_keys else short_keys;
    try writeFooterLine(w, cols, keys, meta);
}

fn writeFooterLine(w: *std.Io.Writer, cols: usize, keys: []const u8, meta: []const u8) !void {
    try w.writeAll(keys);
    if (cols > keys.len + meta.len) {
        var spaces = cols - keys.len - meta.len;
        while (spaces > 0) : (spaces -= 1) try w.writeByte(' ');
    } else {
        try w.writeByte(' ');
    }
    try w.writeAll(meta);
}

pub fn footerForTest(allocator: Allocator, cols: usize, keys: []const u8, meta: []const u8) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try writeFooterLine(&out.writer, cols, keys, meta);
    return out.toOwnedSlice();
}

fn visibleGameRows(body_rows: usize) usize {
    return if (body_rows > game_list_header_rows) body_rows - game_list_header_rows else 0;
}

pub fn visibleGameRowsForTest(body_rows: usize) usize {
    return visibleGameRows(body_rows);
}

pub fn bodyRowsForTest(rows: usize, has_error: bool) usize {
    return bodyRows(rows, has_error);
}

fn renderGames(w: *std.Io.Writer, app: *App, page: model.ParsedPage, max_lines: usize) !void {
    var filtered_index: usize = 0;
    var any_live = false;
    for (page.games) |game| {
        if (game.status == .live and app.matchesFilter(game)) any_live = true;
    }
    const capacity = visibleGameRows(max_lines);
    var emitted: usize = 0;
    if (any_live) try w.writeAll("LIVE") else try w.writeAll("GAMES");
    if (app.scroll > 0) try w.print(" (↑{d})", .{app.scroll});
    try w.writeByte('\n');
    for (page.games) |game| {
        if (!app.matchesFilter(game)) continue;
        if (filtered_index < app.scroll) {
            filtered_index += 1;
            continue;
        }
        if (emitted >= capacity) return;
        const selected = filtered_index == app.selected;
        const prefix = if (selected) "> " else "  ";
        try renderGameLine(w, prefix, game);
        filtered_index += 1;
        emitted += 1;
    }
    if (filtered_index == 0) try w.writeAll("No games match filter. Press / to change.\n");
}

fn renderGameLine(w: *std.Io.Writer, prefix: []const u8, game: model.Game) !void {
    const league = if (game.sport == .unknown) "" else game.league_name;
    const status_mark = statusLabel(game.status);
    const parts = splitGameText(game.status_text);

    try w.writeAll(prefix);
    try writeCell(w, league, league_col_width);
    try w.writeByte(' ');
    try writeCell(w, status_mark, status_col_width);
    try w.writeByte(' ');
    try writeCell(w, game.title, matchup_col_width);
    try w.writeByte(' ');
    try writeCell(w, parts.event, event_col_width);
    try w.writeByte(' ');
    try writeTimeCell(w, parts.time, time_col_width);
    if (game.network) |network| try w.print(" {s}", .{network});
    try w.writeByte('\n');
}

fn writeCell(w: *std.Io.Writer, value: []const u8, width: usize) !void {
    const n = @min(value.len, width);
    try w.writeAll(value[0..n]);
    var spaces = width - n;
    while (spaces > 0) : (spaces -= 1) try w.writeByte(' ');
}

fn writeTimeCell(w: *std.Io.Writer, value: []const u8, width: usize) !void {
    const extra = if (needsHourPadding(value)) @as(usize, 1) else 0;
    var written: usize = 0;
    if (extra != 0 and written < width) {
        try w.writeByte('0');
        written += 1;
    }
    const n = @min(value.len, width - written);
    try w.writeAll(value[0..n]);
    written += n;
    var spaces = width - written;
    while (spaces > 0) : (spaces -= 1) try w.writeByte(' ');
}

fn needsHourPadding(value: []const u8) bool {
    return value.len >= "H:".len and std.ascii.isDigit(value[0]) and value[1] == ':';
}

pub fn normalizeTimeForTest(allocator: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (needsHourPadding(value)) try out.append(allocator, '0');
    try out.appendSlice(allocator, value);
    return out.toOwnedSlice(allocator);
}

fn statusLabel(status: model.StatusKind) []const u8 {
    return switch (status) {
        .live => "LIVE",
        .upcoming => "UP",
        .final => "FINAL",
        .postponed => "PPD",
        .unknown => "",
    };
}

const GameTextParts = struct {
    event: []const u8,
    time: []const u8,
};

fn splitGameText(text: []const u8) GameTextParts {
    const t = std.mem.trim(u8, text, " \t");
    if (std.mem.indexOf(u8, t, " PM")) |pm| return splitBeforeTimeZone(t, pm, " PM ET".len);
    if (std.mem.indexOf(u8, t, " AM")) |am| return splitBeforeTimeZone(t, am, " AM ET".len);
    return .{ .event = "", .time = t };
}

fn splitBeforeTimeZone(text: []const u8, zone_index: usize, suffix_len: usize) GameTextParts {
    const time_end = @min(text.len, zone_index + suffix_len);
    var time_start = zone_index;
    while (time_start > 0 and text[time_start - 1] != ' ') time_start -= 1;
    const event = std.mem.trim(u8, text[0..time_start], " \t");
    const time = std.mem.trim(u8, text[time_start..time_end], " \t");
    return .{ .event = event, .time = time };
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
        if (lines >= max_lines) return;
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
        if (b[0] == escape_key) break;
        if (b[0] == delete_key or b[0] == backspace_key) {
            if (list.items.len > 0) list.shrinkRetainingCapacity(list.items.len - single_row_step);
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

fn openUrl(io: std.Io, url: []const u8) !void {
    const builtin = @import("builtin");
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "open", url },
        .windows => &.{ "cmd", "/C", "start", "", url },
        else => &.{ "xdg-open", url },
    };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = builtin.os.tag == .windows,
    });
    _ = try child.wait(io);
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

fn terminalRows() usize {
    const size = terminalSize();
    return size.rows;
}

fn terminalCols() usize {
    const size = terminalSize();
    return size.cols;
}

const TermSize = struct { rows: usize, cols: usize };
fn terminalSize() TermSize {
    if (@import("builtin").os.tag == .linux) {
        var ws: std.posix.winsize = undefined;
        const rc = std.os.linux.ioctl(std.posix.STDOUT_FILENO, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
        return .{
            .rows = if (rc == 0 and ws.row > 0) ws.row else fallback_terminal_rows,
            .cols = if (rc == 0 and ws.col > 0) ws.col else fallback_terminal_cols,
        };
    }
    return .{ .rows = fallback_terminal_rows, .cols = fallback_terminal_cols };
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeFrame(io: std.Io, bytes: []const u8) !void {
    var start: usize = 0;
    for (bytes, 0..) |b, i| {
        if (b != '\n') continue;
        if (i > start) try writeStdout(io, bytes[start..i]);
        try writeStdout(io, "\x1b[K\n");
        start = i + 1;
    }
    if (start < bytes.len) try writeStdout(io, bytes[start..]);
    try writeStdout(io, "\x1b[K\x1b[J");
}

pub fn frameForTest(allocator: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var start: usize = 0;
    for (bytes, 0..) |b, i| {
        if (b != '\n') continue;
        if (i > start) try out.appendSlice(allocator, bytes[start..i]);
        try out.appendSlice(allocator, "\x1b[K\n");
        start = i + 1;
    }
    if (start < bytes.len) try out.appendSlice(allocator, bytes[start..]);
    try out.appendSlice(allocator, "\x1b[K\x1b[J");
    return out.toOwnedSlice(allocator);
}
