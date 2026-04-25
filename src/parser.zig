const std = @import("std");
pub const model = @import("model.zig");
pub const routes = @import("routes.zig");

const Allocator = std.mem.Allocator;

pub fn parsePage(allocator: Allocator, url: []const u8, html: []const u8) !model.ParsedPage {
    const links = try extractLinks(allocator, html);
    errdefer {
        for (links) |link| link.deinit(allocator);
        allocator.free(links);
    }

    const visible_text = try stripTagsToText(allocator, html);
    errdefer allocator.free(visible_text);

    const games = try parseGamesFromVisibleText(allocator, url, visible_text, links);
    errdefer {
        for (games) |game| game.deinit(allocator);
        allocator.free(games);
    }

    return .{
        .url = try allocator.dupe(u8, url),
        .kind = detectPageKind(url, visible_text),
        .title = if (try extractHtmlTitle(allocator, html)) |t| t else try extractTitle(allocator, visible_text),
        .loaded_at_text = try findLineDup(allocator, visible_text, "Page loaded"),
        .data_loaded_at_text = try findLineDup(allocator, visible_text, "Data loaded"),
        .links = links,
        .games = games,
        .visible_text = visible_text,
    };
}

pub fn extractLinks(allocator: Allocator, html: []const u8) ![]model.Link {
    var list: std.ArrayList(model.Link) = .empty;
    errdefer {
        for (list.items) |link| link.deinit(allocator);
        list.deinit(allocator);
    }

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, html, pos, "<a")) |a_start| {
        const tag_end = std.mem.indexOfPos(u8, html, a_start, ">") orelse break;
        const tag = html[a_start..tag_end];
        const href_value = findAttr(tag, "href") orelse {
            pos = tag_end + 1;
            continue;
        };
        const close = std.ascii.indexOfIgnoreCasePos(html, tag_end + 1, "</a>") orelse {
            pos = tag_end + 1;
            continue;
        };
        const inner = html[tag_end + 1 .. close];
        const text_raw = try stripTagsToText(allocator, inner);
        defer allocator.free(text_raw);
        const text_trim = std.mem.trim(u8, text_raw, " \t\r\n");
        if (text_trim.len == 0) {
            pos = close + 4;
            continue;
        }
        const href_trim = std.mem.trim(u8, href_value, " \t\r\n");
        if (isExternal(href_trim)) {
            pos = close + 4;
            continue;
        }
        const href = try routes.absoluteUrl(allocator, href_trim);
        errdefer allocator.free(href);
        const text = try allocator.dupe(u8, text_trim);
        errdefer allocator.free(text);
        try list.append(allocator, .{ .href = href, .text = text });
        pos = close + 4;
    }
    return list.toOwnedSlice(allocator);
}

fn findAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(tag, pos, name)) |idx| {
        var p = idx + name.len;
        while (p < tag.len and std.ascii.isWhitespace(tag[p])) p += 1;
        if (p >= tag.len or tag[p] != '=') {
            pos = p;
            continue;
        }
        p += 1;
        while (p < tag.len and std.ascii.isWhitespace(tag[p])) p += 1;
        if (p >= tag.len) return null;
        if (tag[p] == '"' or tag[p] == '\'') {
            const q = tag[p];
            p += 1;
            const end = std.mem.indexOfScalarPos(u8, tag, p, q) orelse return null;
            return tag[p..end];
        }
        const start = p;
        while (p < tag.len and !std.ascii.isWhitespace(tag[p]) and tag[p] != '>') p += 1;
        return tag[start..p];
    }
    return null;
}

fn isExternal(href: []const u8) bool {
    return (std.mem.startsWith(u8, href, "http://") or std.mem.startsWith(u8, href, "https://")) and
        !std.mem.startsWith(u8, href, model.base_url);
}

pub fn stripTagsToText(allocator: Allocator, html: []const u8) ![]const u8 {
    const input = bodySlice(html);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var blank_lines: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '<') {
            if (std.ascii.indexOfIgnoreCasePos(input, i, "<script") == i) {
                if (std.ascii.indexOfIgnoreCasePos(input, i, "</script>")) |end| i = end + 9 else i = input.len;
                continue;
            }
            if (std.ascii.indexOfIgnoreCasePos(input, i, "<style") == i) {
                if (std.ascii.indexOfIgnoreCasePos(input, i, "</style>")) |end| i = end + 8 else i = input.len;
                continue;
            }
            const tag_end = std.mem.indexOfScalarPos(u8, input, i, '>') orelse break;
            const tag = input[i .. tag_end + 1];
            if (tagWantsNewline(tag)) try appendNewline(&out, allocator, &blank_lines);
            i = tag_end + 1;
            continue;
        }
        if (c == '&') {
            if (decodeEntity(input[i..])) |ent| {
                try appendByte(&out, allocator, ent.ch, &blank_lines);
                i += ent.len;
                continue;
            }
        }
        try appendByte(&out, allocator, c, &blank_lines);
        i += 1;
    }
    const raw = try out.toOwnedSlice(allocator);
    defer allocator.free(raw);
    return normalizeVisibleText(allocator, raw);
}

fn bodySlice(html: []const u8) []const u8 {
    const body_start_tag = std.ascii.indexOfIgnoreCase(html, "<body") orelse return html;
    const body_start = std.mem.indexOfScalarPos(u8, html, body_start_tag, '>') orelse return html[body_start_tag..];
    const body_end = std.ascii.indexOfIgnoreCasePos(html, body_start + 1, "</body>") orelse html.len;
    return html[body_start + 1 .. body_end];
}

fn normalizeVisibleText(allocator: Allocator, text: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line_raw| {
        var line = std.mem.trimEnd(u8, line_raw, " \t\r");
        line = trimLeftKeepingIndent(line);
        if (line.len != 0 and isNoiseLine(line)) continue;
        try lines.append(allocator, line);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var saw_content = false;
    var blank_pending = false;
    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const line = lines.items[i];
        if (line.len == 0) {
            if (saw_content) blank_pending = true;
            continue;
        }

        if (blank_pending and out.items.len > 0) try out.append(allocator, '\n');
        if (i + 1 < lines.items.len and shouldJoinTeamLines(line, lines.items[i + 1])) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, ' ');
            try appendRecordSpaced(&out, allocator, lines.items[i + 1]);
            try out.append(allocator, '\n');
            i += 1;
        } else {
            try appendRecordSpaced(&out, allocator, line);
            try out.append(allocator, '\n');
        }
        saw_content = true;
        blank_pending = false;
    }
    return out.toOwnedSlice(allocator);
}

fn isNoiseLine(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0) return false;
    if (std.mem.eql(u8, t, "Dark ModeLight Mode")) return true;
    if (std.mem.startsWith(u8, t, "< All ")) return true;
    if (std.mem.startsWith(u8, t, "< ") and std.mem.indexOf(u8, t, " Scores") != null) return true;
    if (std.mem.eql(u8, t, "Play-by-Play   Box Score")) return true;
    if (std.mem.eql(u8, t, "Probable Pitchers")) return true;
    if (std.mem.indexOf(u8, t, "plaintextsports.com | Mobile App") != null) return true;
    if (std.mem.indexOf(u8, t, "Twitter | Instagram | Twitch") != null) return true;
    if (std.mem.eql(u8, t, ".                                           .")) return true;
    if (std.mem.startsWith(u8, t, "Built by ")) return true;
    return false;
}

fn shouldJoinTeamLines(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    if (!std.ascii.isAlphabetic(a[a.len - 1])) return false;
    return trailingRecordStart(b) != null;
}

fn appendRecordSpaced(out: *std.ArrayList(u8), allocator: Allocator, line: []const u8) !void {
    if (trailingRecordStart(line)) |idx| {
        if (idx > 0 and std.ascii.isAlphabetic(line[idx - 1])) {
            try out.appendSlice(allocator, line[0..idx]);
            try out.append(allocator, ' ');
            try out.appendSlice(allocator, line[idx..]);
            return;
        }
    }
    try out.appendSlice(allocator, line);
}

fn trailingRecordStart(line: []const u8) ?usize {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (!std.ascii.isDigit(line[i])) continue;
        const suffix = line[i..];
        if (looksRecordToken(suffix)) return i;
    }
    return null;
}

fn looksRecordToken(token: []const u8) bool {
    if (token.len < 2) return false;
    var has_digit = false;
    var has_marker = false;
    for (token) |c| {
        if (std.ascii.isDigit(c)) {
            has_digit = true;
        } else if (c == '-' or c == 'W' or c == 'L' or c == 'T' or c == 'p') {
            has_marker = true;
        } else return false;
    }
    return has_digit and has_marker;
}

fn trimLeftKeepingIndent(line: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0) return trimmed;
    // Keep ASCII table / box alignment; remove layout-only leading spaces elsewhere.
    if (std.mem.startsWith(u8, trimmed, "+-") or std.mem.startsWith(u8, trimmed, "|") or std.mem.startsWith(u8, trimmed, "---")) return trimmed;
    return trimmed;
}

fn tagWantsNewline(tag: []const u8) bool {
    const names = [_][]const u8{ "<br", "</p", "<p", "</div", "<div", "</tr", "<tr", "</li", "<li", "</h", "<h", "<pre", "</pre" };
    for (names) |name| if (std.ascii.indexOfIgnoreCase(tag, name) != null) return true;
    return false;
}

const Entity = struct { ch: u8, len: usize };
fn decodeEntity(s: []const u8) ?Entity {
    const ents = [_]struct { name: []const u8, ch: u8 }{
        .{ .name = "&amp;", .ch = '&' },
        .{ .name = "&lt;", .ch = '<' },
        .{ .name = "&gt;", .ch = '>' },
        .{ .name = "&quot;", .ch = '"' },
        .{ .name = "&#39;", .ch = '\'' },
        .{ .name = "&nbsp;", .ch = ' ' },
    };
    for (ents) |ent| if (std.mem.startsWith(u8, s, ent.name)) return .{ .ch = ent.ch, .len = ent.name.len };
    return null;
}

fn appendByte(out: *std.ArrayList(u8), allocator: Allocator, c: u8, blank_lines: *usize) !void {
    if (c == '\r') return;
    if (c == '\n') return appendNewline(out, allocator, blank_lines);
    blank_lines.* = 0;
    try out.append(allocator, c);
}

fn appendNewline(out: *std.ArrayList(u8), allocator: Allocator, blank_lines: *usize) !void {
    if (out.items.len == 0) return;
    if (out.items[out.items.len - 1] == '\n') {
        blank_lines.* += 1;
        if (blank_lines.* >= 2) return;
    } else {
        blank_lines.* = 0;
    }
    try out.append(allocator, '\n');
}

pub fn parseGamesFromVisibleText(allocator: Allocator, url: []const u8, text: []const u8, links: []const model.Link) ![]model.Game {
    var games: std.ArrayList(model.Game) = .empty;
    errdefer {
        for (games.items) |game| game.deinit(allocator);
        games.deinit(allocator);
    }

    var line_it = std.mem.splitScalar(u8, text, '\n');
    var in_block = false;
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(allocator);

    while (line_it.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, " \t\r");
        if (!in_block and std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "+-")) {
            in_block = true;
            block.clearRetainingCapacity();
        }
        if (in_block) {
            try block.appendSlice(allocator, line);
            try block.append(allocator, '\n');
            if (block.items.len > 3 and std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "+-") and !isFirstBlockLine(block.items)) {
                const game = try gameFromBlock(allocator, url, block.items, links, games.items.len);
                try games.append(allocator, game);
                in_block = false;
            }
        }
    }
    return games.toOwnedSlice(allocator);
}

fn isFirstBlockLine(block: []const u8) bool {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
    }
    return count <= 1;
}

fn gameFromBlock(allocator: Allocator, url: []const u8, block: []const u8, links: []const model.Link, idx: usize) !model.Game {
    var payload_lines: std.ArrayList([]const u8) = .empty;
    defer payload_lines.deinit(allocator);

    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0 or std.mem.startsWith(u8, t, "+-")) continue;
        if (std.mem.indexOfScalar(u8, t, '|')) |_| {
            const cleaned = cleanBoxLine(t);
            if (cleaned.len > 0) try payload_lines.append(allocator, cleaned);
        }
    }

    const status_text = if (payload_lines.items.len > 0) std.mem.trim(u8, payload_lines.items[0], " ") else "";
    const status = detectStatus(status_text, block);
    const network = detectNetwork(block);
    const maybe_url = findGameUrl(allocator, links, idx) catch null;
    errdefer if (maybe_url) |v| allocator.free(v);
    const sport = if (maybe_url) |game_url| detectSport(game_url, block) else detectSport(url, block);
    const away = if (payload_lines.items.len >= 2) try cleanTeamLineDup(allocator, payload_lines.items[1]) else null;
    errdefer if (away) |v| allocator.free(v);
    const home = if (payload_lines.items.len >= 3) try cleanTeamLineDup(allocator, payload_lines.items[2]) else null;
    errdefer if (home) |v| allocator.free(v);

    const title = if (away != null and home != null)
        try std.fmt.allocPrint(allocator, "{s} @ {s}", .{ teamCode(away.?), teamCode(home.?) })
    else
        try firstMeaningfulTitle(allocator, block);
    errdefer allocator.free(title);

    return .{
        .sport = sport,
        .league_name = try allocator.dupe(u8, sport.label()),
        .title = title,
        .away = away,
        .home = home,
        .status = status,
        .status_text = try allocator.dupe(u8, status_text),
        .network = if (network) |n| try allocator.dupe(u8, n) else null,
        .url = maybe_url,
        .raw_block = try allocator.dupe(u8, block),
    };
}

fn cleanBoxLine(line: []const u8) []const u8 {
    var t = std.mem.trim(u8, line, " \t|");
    if (std.mem.lastIndexOf(u8, t, "|")) |idx| t = std.mem.trim(u8, t[0..idx], " \t|");
    return t;
}

fn cleanTeamLineDup(allocator: Allocator, line: []const u8) !?[]const u8 {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0) return null;
    return try allocator.dupe(u8, t);
}

fn teamCode(line: []const u8) []const u8 {
    var t = std.mem.trim(u8, line, " ");
    while (t.len > 0 and (std.ascii.isDigit(t[0]) or t[0] == '#')) t = std.mem.trimStart(u8, t[1..], " ");
    var end: usize = 0;
    while (end < t.len and !std.ascii.isWhitespace(t[end])) end += 1;
    return t[0..end];
}

fn firstMeaningfulTitle(allocator: Allocator, block: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, cleanBoxLine(line), " ");
        if (t.len > 0 and !std.mem.startsWith(u8, t, "+-")) return allocator.dupe(u8, t);
    }
    return allocator.dupe(u8, "Game");
}

pub fn detectStatus(status_line: []const u8, block: []const u8) model.StatusKind {
    const hay = if (status_line.len > 0) status_line else block;
    if (std.ascii.indexOfIgnoreCase(hay, "Postponed") != null) return .postponed;
    if (std.ascii.indexOfIgnoreCase(hay, "Final") != null or std.ascii.indexOfIgnoreCase(hay, "FT") != null) return .final;
    if (looksUpcoming(hay)) return .upcoming;
    const live_terms = [_][]const u8{ "Top", "Bottom", "Mid", "End", "Q1", "Q2", "Q3", "Q4", "OT", "1st", "2nd", "3rd", "Period", "Half", "live", "In Progress" };
    for (live_terms) |term| if (std.ascii.indexOfIgnoreCase(hay, term) != null) return .live;
    return .unknown;
}

fn looksUpcoming(s: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(s, "AM") != null or std.ascii.indexOfIgnoreCase(s, "PM") != null) return true;
    return false;
}

fn detectNetwork(block: []const u8) ?[]const u8 {
    const networks = [_][]const u8{ "ESPN", "ESPN2", "ABC", "FOX", "FS1", "TNT", "TBS", "Prime", "NBC", "CBS", "SN", "MLBN", "NBATV", "NHLN", "Victory+", "Apple TV" };
    for (networks) |n| if (std.ascii.indexOfIgnoreCase(block, n) != null) return n;
    return null;
}

fn findGameUrl(allocator: Allocator, links: []const model.Link, idx: usize) !?[]const u8 {
    var count: usize = 0;
    for (links) |link| {
        if (isGameLink(link)) {
            if (count == idx) return try allocator.dupe(u8, link.href);
            count += 1;
        }
    }
    return null;
}

fn isGameLink(link: model.Link) bool {
    if (std.mem.indexOf(u8, link.href, "/all/") != null) return false;
    if (std.ascii.indexOfIgnoreCase(link.href, "schedule") != null) return false;
    if (std.ascii.indexOfIgnoreCase(link.href, "standings") != null) return false;
    if (std.ascii.indexOfIgnoreCase(link.href, "teams") != null) return false;
    return std.mem.startsWith(u8, std.mem.trim(u8, link.text, " \t\r\n"), "+-");
}

pub fn detectPageKind(url: []const u8, text: []const u8) model.PageKind {
    if (std.ascii.indexOfIgnoreCase(url, "schedule") != null or std.ascii.indexOfIgnoreCase(text, "Schedule") != null) return .schedule;
    if (std.ascii.indexOfIgnoreCase(url, "standings") != null or std.ascii.indexOfIgnoreCase(text, "Standings") != null) return .standings;
    if (std.ascii.indexOfIgnoreCase(url, "teams") != null or std.ascii.indexOfIgnoreCase(text, "Teams") != null) return .teams;
    if (std.mem.indexOf(u8, url, "/20") != null) return .game;
    if (std.mem.eql(u8, url, model.base_url) or std.mem.eql(u8, url, model.base_url ++ "/")) return .home;
    if (detectSport(url, text) != .unknown) return .sport_home;
    return .unknown;
}

pub fn detectSport(url: []const u8, text: []const u8) model.Sport {
    _ = text;
    const pairs = [_]struct { needle: []const u8, sport: model.Sport }{
        .{ .needle = "/mlb", .sport = .mlb },
        .{ .needle = "/nba", .sport = .nba },
        .{ .needle = "/nhl", .sport = .nhl },
        .{ .needle = "/nfl", .sport = .nfl },
        .{ .needle = "/college-football", .sport = .ncaaf },
        .{ .needle = "/college-basketball", .sport = .ncaamb },
        .{ .needle = "/wnba", .sport = .wnba },
        .{ .needle = "/soccer", .sport = .soccer },
        .{ .needle = "/nwsl", .sport = .soccer },
        .{ .needle = "/mls", .sport = .soccer },
        .{ .needle = "/premier-league", .sport = .soccer },
        .{ .needle = "/champions-league", .sport = .soccer },
        .{ .needle = "/europa-league", .sport = .soccer },
    };
    for (pairs) |p| if (std.ascii.indexOfIgnoreCase(url, p.needle) != null) return p.sport;
    return .unknown;
}

fn extractHtmlTitle(allocator: Allocator, html: []const u8) !?[]const u8 {
    const start_tag = std.ascii.indexOfIgnoreCase(html, "<title>") orelse return null;
    const content_start = start_tag + "<title>".len;
    const end = std.ascii.indexOfIgnoreCasePos(html, content_start, "</title>") orelse return null;
    const raw = try stripTagsToText(allocator, html[content_start..end]);
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn extractTitle(allocator: Allocator, text: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0) return allocator.dupe(u8, t);
    }
    return allocator.dupe(u8, "Plain Text Sports");
}

fn findLineDup(allocator: Allocator, text: []const u8, needle: []const u8) !?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.ascii.indexOfIgnoreCase(line, needle) != null) return try allocator.dupe(u8, std.mem.trim(u8, line, " \t\r"));
    }
    return null;
}
