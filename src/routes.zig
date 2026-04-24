const std = @import("std");
const model = @import("model.zig");

pub const Route = struct {
    sport: model.Sport,
    name: []const u8,
    path: []const u8,
};

pub const routes = [_]Route{
    .{ .sport = .all, .name = "All Sports", .path = "/" },
    .{ .sport = .mlb, .name = "MLB", .path = "/mlb/" },
    .{ .sport = .nba, .name = "NBA", .path = "/nba/" },
    .{ .sport = .nhl, .name = "NHL", .path = "/nhl/" },
    .{ .sport = .nfl, .name = "NFL", .path = "/nfl/" },
    .{ .sport = .ncaaf, .name = "NCAAF", .path = "/college-football/" },
    .{ .sport = .ncaamb, .name = "NCAAMB", .path = "/college-basketball/" },
    .{ .sport = .wnba, .name = "WNBA", .path = "/wnba/" },
    .{ .sport = .soccer, .name = "Soccer", .path = "/soccer/" },
};

pub fn pathForSport(sport: model.Sport) []const u8 {
    for (routes) |route| if (route.sport == sport) return route.path;
    return "/";
}

pub fn absoluteUrl(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "https://")) {
        return allocator.dupe(u8, input);
    }
    if (std.mem.startsWith(u8, input, "/")) {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ model.base_url, input });
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ model.base_url, input });
}

pub fn isPageShortcut(arg: []const u8) bool {
    return std.ascii.eqlIgnoreCase(arg, "schedule") or
        std.ascii.eqlIgnoreCase(arg, "standings") or
        std.ascii.eqlIgnoreCase(arg, "teams");
}

pub fn findShortcutLink(links: []const model.Link, shortcut: []const u8) ?[]const u8 {
    for (links) |link| {
        if (std.ascii.indexOfIgnoreCase(link.text, shortcut) != null) return link.href;
        if (std.ascii.indexOfIgnoreCase(link.href, shortcut) != null) return link.href;
    }
    return null;
}
