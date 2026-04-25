const std = @import("std");
const model = @import("model.zig");
const routes = @import("routes.zig");

pub const Options = struct {
    sport: model.Sport = .all,
    shortcut: ?[]const u8 = null,
    url: ?[]const u8 = null,
    plain: bool = false,
    no_cache: bool = false,
    debug: bool = false,
    color: bool = true,
    refresh_seconds: u64 = 15,
    help: bool = false,
    version: bool = false,
};

pub const CliError = error{ UnknownArgument, MissingValue, InvalidRefresh };

pub fn parseArgs(args: []const []const u8) CliError!Options {
    var opts: Options = .{};
    var positional: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--plain")) {
            opts.plain = true;
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            opts.no_cache = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            opts.debug = true;
        } else if (std.mem.eql(u8, arg, "--color")) {
            opts.color = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            opts.color = false;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            opts.help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            opts.version = true;
        } else if (std.mem.eql(u8, arg, "--refresh")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.refresh_seconds = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidRefresh;
            if (opts.refresh_seconds == 0) return error.InvalidRefresh;
        } else if (std.mem.eql(u8, arg, "--url")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.url = args[i];
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownArgument;
        } else {
            switch (positional) {
                0 => {
                    const sport = model.sportFromArg(arg);
                    if (sport == .unknown and !std.mem.eql(u8, arg, "live")) return error.UnknownArgument;
                    opts.sport = sport;
                },
                1 => {
                    if (!routes.isPageShortcut(arg)) return error.UnknownArgument;
                    opts.shortcut = arg;
                },
                else => return error.UnknownArgument,
            }
            positional += 1;
        }
    }
    return opts;
}

pub fn printHelp(writer: anytype) !void {
    try writer.print(
        \\pts - terminal UI for Plain Text Sports
        \\
        \\Usage:
        \\  pts [sport] [schedule|standings|teams]
        \\  pts --plain
        \\  pts nba --plain
        \\  pts --url <url>
        \\
        \\Sports: live all mlb nba nhl nfl ncaaf ncaamb wnba soccer
        \\
        \\Flags:
        \\  --refresh <seconds>   Auto-refresh interval (default: 15)
        \\  --no-cache            Disable cache fallback
        \\  --plain               Print text and exit
        \\  --debug               Print parser/network details to stderr
        \\  --color               Enable ANSI colors (default)
        \\  --no-color            Disable ANSI colors
        \\  --url <url>           Open Plain Text Sports URL/path
        \\  --version             Print version
        \\  --help                Print help
        \\
        \\Keys: j/down move · k/up move · h/left prev day · l/right next day · enter open · r refresh · / filter · a auto · ? help · b back · q quit
        \\
    , .{});
}
