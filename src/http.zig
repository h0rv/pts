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
