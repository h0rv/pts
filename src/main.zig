const std = @import("std");
const cli = @import("cli.zig");
const model = @import("model.zig");
const routes = @import("routes.zig");
const http = @import("http.zig");
const parser = @import("parser.zig");
const cache = @import("cache.zig");
const ui = @import("ui.zig");
const style = @import("style.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_iter.deinit();
    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(gpa);
    while (args_iter.next()) |arg| try args_list.append(gpa, arg);
    const args = args_list.items;

    const opts = cli.parseArgs(args) catch |err| {
        try printErr(io, "argument error: {any}\n\n", .{err});
        var stderr_buf: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
        try cli.printHelp(&stderr.interface);
        try stderr.interface.flush();
        std.process.exit(2);
    };

    if (opts.help) {
        var stdout_buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
        try cli.printHelp(&stdout.interface);
        try stdout.interface.flush();
        return;
    }
    if (opts.version) {
        var stdout_buf: [128]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
        try stdout.interface.print("pts {s}\n", .{model.version});
        try stdout.interface.flush();
        return;
    }

    var client = http.initClient(gpa, io);
    defer client.deinit();

    const url = try resolveUrl(gpa, &client, opts);
    defer gpa.free(url);
    const cache_root = try cache.defaultDir(gpa, init.environ_map);
    defer gpa.free(cache_root);

    const color = opts.color and init.environ_map.get("NO_COLOR") == null;
    if (opts.plain) {
        try plain(io, gpa, &client, opts, cache_root, url, color);
        return;
    }

    try ui.run(gpa, io, &client, cache_root, url, opts.refresh_seconds, !opts.no_cache, opts.debug, color);
}

fn resolveUrl(allocator: std.mem.Allocator, client: *std.http.Client, opts: cli.Options) ![]u8 {
    if (opts.url) |u| return routes.absoluteUrl(allocator, u);

    const path = if (opts.date) |date| try routes.datedPath(allocator, opts.sport, date) else try allocator.dupe(u8, routes.pathForSport(opts.sport));
    defer allocator.free(path);
    const base = try routes.absoluteUrl(allocator, path);
    errdefer allocator.free(base);

    if (opts.shortcut) |shortcut| {
        const body = try http.fetchPage(allocator, client, base);
        defer allocator.free(body);
        var parsed = try parser.parsePage(allocator, base, body);
        defer parsed.deinit(allocator);
        if (routes.findShortcutLink(parsed.links, shortcut)) |href| {
            allocator.free(base);
            return allocator.dupe(u8, href);
        }
        return error.ShortcutNotFound;
    }

    return base;
}

fn plain(io: std.Io, allocator: std.mem.Allocator, client: *std.http.Client, opts: cli.Options, cache_root: []const u8, url: []const u8, color: bool) !void {
    const body = http.fetchPage(allocator, client, url) catch |err| {
        if (!opts.no_cache) {
            if (cache.read(client.io, allocator, cache_root, url) catch null) |cached| {
                defer allocator.free(cached);
                return printParsed(io, allocator, url, cached, color);
            }
        }
        return err;
    };
    defer allocator.free(body);
    if (!opts.no_cache) cache.write(client.io, allocator, cache_root, url, body) catch |err| if (opts.debug) std.debug.print("cache write error: {any}\n", .{err});
    try printParsed(io, allocator, url, body, color);
}

fn printParsed(io: std.Io, allocator: std.mem.Allocator, url: []const u8, body: []const u8, color: bool) !void {
    var parsed = try parser.parsePage(allocator, url, body);
    defer parsed.deinit(allocator);

    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout.interface;
    if (parsed.games.len > 0) {
        try style.write(w, color, .title, parsed.title);
        try w.writeByte('\n');
        try style.write(w, color, .dim, parsed.url);
        try w.writeAll("\n\n");
        for (parsed.games) |game| {
            try style.writeCell(w, color, .league, game.league_name, 5);
            try w.writeByte(' ');
            try style.writeCell(w, color, plainStatusStyle(game.status), @tagName(game.status), 8);
            try w.print(" {s} — {s}", .{ game.title, game.status_text });
            if (game.network) |n| {
                try w.writeAll(" ");
                try style.write(w, color, .network, n);
            }
            if (game.url) |u| {
                try w.writeAll(" ");
                try style.write(w, color, .dim, u);
            }
            try w.writeAll("\n");
        }
    } else {
        try w.writeAll(parsed.visible_text);
        if (parsed.visible_text.len == 0 or parsed.visible_text[parsed.visible_text.len - 1] != '\n') try w.writeByte('\n');
    }
    try w.flush();
}

fn plainStatusStyle(status: model.StatusKind) style.Kind {
    return switch (status) {
        .live => .live,
        .upcoming => .up,
        .final => .final,
        .postponed => .postponed,
        .unknown => .dim,
    };
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var stderr_buf: [2048]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}
