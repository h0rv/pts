const std = @import("std");
const parser = @import("parser");
const model = parser.model;
const routes = parser.routes;

fn readTestFile(parts: []const []const u8) ![]u8 {
    const path = try std.fs.path.join(std.testing.allocator, parts);
    defer std.testing.allocator.free(path);
    return try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
}

fn fixture(name: []const u8) ![]u8 {
    return readTestFile(&.{ "testdata", name });
}

fn snapshot(parts: []const []const u8) ![]u8 {
    return readTestFile(parts);
}

fn expectSnapshot(expected: []const u8, actual: []const u8) !void {
    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print("\n--- expected ---\n{s}\n--- actual ---\n{s}\n", .{ expected, actual });
        return error.SnapshotMismatch;
    }
}

fn renderGamesSnapshot(page: model.ParsedPage) ![]u8 {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer out.deinit();
    for (page.games) |game| {
        try out.writer.print("{s}|{s}|{s}|{s}|", .{ game.sport.label(), @tagName(game.status), game.title, game.status_text });
        if (game.network) |network| try out.writer.writeAll(network);
        try out.writer.writeByte('|');
        if (game.url) |url| try out.writer.writeAll(url);
        try out.writer.writeByte('\n');
    }
    return try out.toOwnedSlice();
}

test "extract links and normalize relative URLs" {
    const html = try fixture("home.html");
    defer std.testing.allocator.free(html);
    const links = try parser.extractLinks(std.testing.allocator, html);
    defer {
        for (links) |link| link.deinit(std.testing.allocator);
        std.testing.allocator.free(links);
    }
    try std.testing.expect(links.len >= 2);
    try std.testing.expectEqualStrings("https://plaintextsports.com/nba/", links[0].href);
    try std.testing.expectEqualStrings("National Basketball Association", links[0].text);
}

test "strip tags decodes entities" {
    const text = try parser.stripTagsToText(std.testing.allocator, "<p>A&amp;B&nbsp;&lt;x&gt;&#39;</p>");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "A&B <x>'") != null);
}

test "detect NBA upcoming block and shortcut link" {
    const html = try fixture("nba.html");
    defer std.testing.allocator.free(html);
    var parsed = try parser.parsePage(std.testing.allocator, "https://plaintextsports.com/nba/", html);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(model.PageKind.schedule, parser.detectPageKind("https://plaintextsports.com/nba/2025-2026/schedule", parsed.visible_text));
    try std.testing.expect(parsed.games.len > 0);
    try std.testing.expectEqual(model.StatusKind.upcoming, parsed.games[0].status);
    try std.testing.expectEqualStrings("Prime", parsed.games[0].network.?);
    try std.testing.expect(routes.findShortcutLink(parsed.links, "Schedule") != null);
}

test "detect MLB live block and game url" {
    const html = try fixture("mlb_live.html");
    defer std.testing.allocator.free(html);
    var parsed = try parser.parsePage(std.testing.allocator, "https://plaintextsports.com/mlb/", html);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.games.len > 0);
    try std.testing.expectEqual(model.StatusKind.live, parsed.games[0].status);
    try std.testing.expectEqualStrings("FS1", parsed.games[0].network.?);
    try std.testing.expect(parsed.games[0].url != null);
}

test "detect final and upcoming blocks" {
    const html = try fixture("nhl_schedule.html");
    defer std.testing.allocator.free(html);
    var parsed = try parser.parsePage(std.testing.allocator, "https://plaintextsports.com/nhl/2025-2026/schedule", html);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed.games.len >= 2);
    try std.testing.expectEqual(model.StatusKind.final, parsed.games[0].status);
    try std.testing.expectEqual(model.StatusKind.upcoming, parsed.games[1].status);
}

test "absolute url maps path" {
    const url = try routes.absoluteUrl(std.testing.allocator, "/nba/");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("https://plaintextsports.com/nba/", url);
}

test "snapshot: game detail visible text is normalized and not leading-blank truncated" {
    const html = try fixture("detail_phi_atl.html");
    defer std.testing.allocator.free(html);
    var parsed = try parser.parsePage(std.testing.allocator, "https://plaintextsports.com/mlb/2026-04-24/phi-atl", html);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(model.PageKind.game, parsed.kind);
    try std.testing.expectEqualStrings("Phillies vs. Braves | April 24, 2026", parsed.title);

    const expected = try snapshot(&.{ "testdata", "snapshots", "detail_phi_atl.visible.txt" });
    defer std.testing.allocator.free(expected);
    try expectSnapshot(expected, parsed.visible_text);
}

test "snapshot: NBA detail visible text is cleaned" {
    const html = try fixture("detail_nba_bos_phi.html");
    defer std.testing.allocator.free(html);
    var parsed = try parser.parsePage(std.testing.allocator, "https://plaintextsports.com/nba/2026-04-24/bos-phi", html);
    defer parsed.deinit(std.testing.allocator);

    const expected = try snapshot(&.{ "testdata", "snapshots", "detail_nba_bos_phi.visible.txt" });
    defer std.testing.allocator.free(expected);
    try expectSnapshot(expected, parsed.visible_text);
}

test "snapshot: NHL detail visible text is cleaned" {
    const html = try fixture("detail_nhl_tbl_mtl.html");
    defer std.testing.allocator.free(html);
    var parsed = try parser.parsePage(std.testing.allocator, "https://plaintextsports.com/nhl/2026-04-24/tbl-mtl", html);
    defer parsed.deinit(std.testing.allocator);

    const expected = try snapshot(&.{ "testdata", "snapshots", "detail_nhl_tbl_mtl.visible.txt" });
    defer std.testing.allocator.free(expected);
    try expectSnapshot(expected, parsed.visible_text);
}

test "snapshot: mixed home page attaches game links and league labels" {
    const html = try fixture("home_mixed.html");
    defer std.testing.allocator.free(html);
    var parsed = try parser.parsePage(std.testing.allocator, "https://plaintextsports.com/", html);
    defer parsed.deinit(std.testing.allocator);

    const actual = try renderGamesSnapshot(parsed);
    defer std.testing.allocator.free(actual);
    const expected = try snapshot(&.{ "testdata", "snapshots", "home_mixed.games.txt" });
    defer std.testing.allocator.free(expected);
    try expectSnapshot(expected, actual);
}
