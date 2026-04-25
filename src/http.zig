const std = @import("std");
const model = @import("model.zig");

pub const max_body_size = 5 * 1024 * 1024;

pub const FetchError = error{
    HttpStatus,
    BodyTooLarge,
} || std.http.Client.FetchError || std.mem.Allocator.Error;

pub fn initClient(allocator: std.mem.Allocator, io: std.Io) std.http.Client {
    return .{ .allocator = allocator, .io = io };
}

pub fn fetchPage(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
) FetchError![]u8 {
    const body = try fetchPageOnce(allocator, client, url);
    errdefer allocator.free(body);
    if (metaRefreshUrl(body)) |next| {
        const absolute = try absoluteUrl(allocator, next);
        defer allocator.free(absolute);
        const redirected = fetchPageOnce(allocator, client, absolute) catch return body;
        allocator.free(body);
        return redirected;
    }
    return body;
}

fn fetchPageOnce(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
) FetchError![]u8 {
    var body = try std.Io.Writer.Allocating.initCapacity(allocator, 32 * 1024);
    errdefer body.deinit();

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var decompress_buffer: [64 * 1024]u8 = undefined;
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(3),
        .response_writer = &body.writer,
        .redirect_buffer = &redirect_buffer,
        .decompress_buffer = &decompress_buffer,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = model.user_agent },
        },
    });
    if (result.status.class() != .success) return error.HttpStatus;
    if (body.written().len > max_body_size) return error.BodyTooLarge;
    return try body.toOwnedSlice();
}

fn metaRefreshUrl(body: []const u8) ?[]const u8 {
    const meta = std.ascii.indexOfIgnoreCase(body, "http-equiv=\"refresh\"") orelse return null;
    const content = std.ascii.indexOfIgnoreCasePos(body, meta, "content=\"") orelse return null;
    const start = content + "content=\"".len;
    const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return null;
    const value = body[start..end];
    const url_pos = std.ascii.indexOfIgnoreCase(value, "url=") orelse return null;
    return std.mem.trim(u8, value[url_pos + "url=".len ..], " \t'\"");
}

fn absoluteUrl(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, input, "http://") or std.mem.startsWith(u8, input, "https://")) return allocator.dupe(u8, input);
    if (std.mem.startsWith(u8, input, "/")) return std.fmt.allocPrint(allocator, "{s}{s}", .{ model.base_url, input });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ model.base_url, input });
}
