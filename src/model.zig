const std = @import("std");

pub const base_url = "https://plaintextsports.com";
pub const version = "0.1.0";
pub const user_agent = "pts-zig/0.1 (+https://github.com/h0rv/pts)";

pub const Sport = enum {
    all,
    mlb,
    nba,
    nhl,
    nfl,
    ncaaf,
    ncaamb,
    wnba,
    soccer,
    unknown,

    pub fn label(self: Sport) []const u8 {
        return switch (self) {
            .all => "All",
            .mlb => "MLB",
            .nba => "NBA",
            .nhl => "NHL",
            .nfl => "NFL",
            .ncaaf => "NCAAF",
            .ncaamb => "NCAAMB",
            .wnba => "WNBA",
            .soccer => "Soccer",
            .unknown => "Unknown",
        };
    }
};

pub const PageKind = enum {
    home,
    sport_home,
    schedule,
    standings,
    teams,
    game,
    unknown,
};

pub const StatusKind = enum {
    live,
    upcoming,
    final,
    postponed,
    unknown,
};

pub const Link = struct {
    href: []const u8,
    text: []const u8,

    pub fn deinit(self: Link, allocator: std.mem.Allocator) void {
        allocator.free(self.href);
        allocator.free(self.text);
    }
};

pub const Game = struct {
    sport: Sport,
    league_name: []const u8,
    title: []const u8,
    away: ?[]const u8,
    home: ?[]const u8,
    status: StatusKind,
    status_text: []const u8,
    network: ?[]const u8,
    url: ?[]const u8,
    raw_block: []const u8,

    pub fn deinit(self: Game, allocator: std.mem.Allocator) void {
        allocator.free(self.league_name);
        allocator.free(self.title);
        if (self.away) |v| allocator.free(v);
        if (self.home) |v| allocator.free(v);
        allocator.free(self.status_text);
        if (self.network) |v| allocator.free(v);
        if (self.url) |v| allocator.free(v);
        allocator.free(self.raw_block);
    }
};

pub const ParsedPage = struct {
    url: []const u8,
    kind: PageKind,
    title: []const u8,
    loaded_at_text: ?[]const u8,
    data_loaded_at_text: ?[]const u8,
    links: []Link,
    games: []Game,
    visible_text: []const u8,

    pub fn deinit(self: ParsedPage, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.title);
        if (self.loaded_at_text) |v| allocator.free(v);
        if (self.data_loaded_at_text) |v| allocator.free(v);
        for (self.links) |link| link.deinit(allocator);
        allocator.free(self.links);
        for (self.games) |game| game.deinit(allocator);
        allocator.free(self.games);
        allocator.free(self.visible_text);
    }
};

pub fn sportFromArg(arg: []const u8) Sport {
    if (std.ascii.eqlIgnoreCase(arg, "all") or std.ascii.eqlIgnoreCase(arg, "live")) return .all;
    if (std.ascii.eqlIgnoreCase(arg, "mlb")) return .mlb;
    if (std.ascii.eqlIgnoreCase(arg, "nba")) return .nba;
    if (std.ascii.eqlIgnoreCase(arg, "nhl")) return .nhl;
    if (std.ascii.eqlIgnoreCase(arg, "nfl")) return .nfl;
    if (std.ascii.eqlIgnoreCase(arg, "ncaaf")) return .ncaaf;
    if (std.ascii.eqlIgnoreCase(arg, "ncaamb")) return .ncaamb;
    if (std.ascii.eqlIgnoreCase(arg, "wnba")) return .wnba;
    if (std.ascii.eqlIgnoreCase(arg, "soccer")) return .soccer;
    return .unknown;
}
