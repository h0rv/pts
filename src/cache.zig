const std = @import("std");

const Entry = struct {
    html_path: []const u8,
    meta_path: []const u8,
};

pub fn read(io: std.Io, allocator: std.mem.Allocator, cache_root: []const u8, url: []const u8) !?[]u8 {
    const entry = try entryPaths(allocator, cache_root, url);
    defer freeEntry(allocator, entry);
    return std.Io.Dir.cwd().readFileAlloc(io, entry.html_path, allocator, .limited(5 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
}

pub fn write(io: std.Io, allocator: std.mem.Allocator, cache_root: []const u8, url: []const u8, body: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, cache_root);

    const entry = try entryPathsFromDir(allocator, cache_root, url);
    defer freeEntry(allocator, entry);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = entry.html_path, .data = body });
    const meta = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "url": "{s}",
        \\  "fetched_at_unix": {d}
        \\}}
        \\
    , .{ url, std.Io.Timestamp.now(io, .real).toSeconds() });
    defer allocator.free(meta);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = entry.meta_path, .data = meta });
}

fn entryPaths(allocator: std.mem.Allocator, cache_root: []const u8, url: []const u8) !Entry {
    return entryPathsFromDir(allocator, cache_root, url);
}

fn entryPathsFromDir(allocator: std.mem.Allocator, dir: []const u8, url: []const u8) !Entry {
    const key = sha256Hex(url);
    const html_name = try std.fmt.allocPrint(allocator, "{s}.html", .{key});
    defer allocator.free(html_name);
    const meta_name = try std.fmt.allocPrint(allocator, "{s}.json", .{key});
    defer allocator.free(meta_name);
    return .{
        .html_path = try std.fs.path.join(allocator, &.{ dir, html_name }),
        .meta_path = try std.fs.path.join(allocator, &.{ dir, meta_name }),
    };
}

fn freeEntry(allocator: std.mem.Allocator, entry: Entry) void {
    allocator.free(entry.html_path);
    allocator.free(entry.meta_path);
}

pub fn defaultDir(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) ![]const u8 {
    if (env.get("XDG_CACHE_HOME")) |xdg| return std.fs.path.join(allocator, &.{ xdg, "pts" });
    if (env.get("HOME")) |home| {
        if (@import("builtin").os.tag == .macos) {
            return std.fs.path.join(allocator, &.{ home, "Library", "Caches", "pts" });
        }
        return std.fs.path.join(allocator, &.{ home, ".cache", "pts" });
    }
    return std.fs.path.join(allocator, &.{ ".zig-cache", "pts" });
}

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = "0123456789abcdef";
    var out: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}
