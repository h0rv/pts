const std = @import("std");
const ui = @import("ui");

const clear_line = "\x1b[K";
const clear_rest = "\x1b[J";
const newline = "\n";
const footer_cols: usize = 60;
const footer_keys = "keys";
const footer_meta = "r:2s auto:on/15s";
const small_terminal_rows: usize = 16;
const footer_row_count: usize = 1;
const game_header_row_count: usize = 1;

test "frame output clears every line tail" {
    const frame = try ui.frameForTest(std.testing.allocator, "long stale footer text\nshort\n");
    defer std.testing.allocator.free(frame);

    try std.testing.expectEqualStrings("long stale footer text" ++ clear_line ++ newline ++ "short" ++ clear_line ++ newline ++ clear_line ++ clear_rest, frame);
}

test "frame output clears tail for unterminated last line" {
    const frame = try ui.frameForTest(std.testing.allocator, "header\nshort");
    defer std.testing.allocator.free(frame);

    try std.testing.expectEqualStrings("header" ++ clear_line ++ newline ++ "short" ++ clear_line ++ clear_rest, frame);
}

test "time normalization pads one-digit hours" {
    const early = try ui.normalizeTimeForTest(std.testing.allocator, "7:00 PM ET");
    defer std.testing.allocator.free(early);
    try std.testing.expectEqualStrings("07:00 PM ET", early);

    const late = try ui.normalizeTimeForTest(std.testing.allocator, "10:30 PM ET");
    defer std.testing.allocator.free(late);
    try std.testing.expectEqualStrings("10:30 PM ET", late);
}

test "body budget reserves footer row" {
    const body_rows = ui.bodyRowsForTest(small_terminal_rows, false);
    try std.testing.expectEqual(small_terminal_rows - footer_row_count, body_rows);
    try std.testing.expectEqual(body_rows - game_header_row_count, ui.visibleGameRowsForTest(body_rows));
}

test "footer keeps meta on right when there is room" {
    const footer = try ui.footerForTest(std.testing.allocator, footer_cols, footer_keys, footer_meta);
    defer std.testing.allocator.free(footer);

    try std.testing.expectEqual(@as(usize, footer_cols), footer.len);
    try std.testing.expect(std.mem.startsWith(u8, footer, footer_keys));
    try std.testing.expect(std.mem.endsWith(u8, footer, footer_meta));
    try std.testing.expect(!std.mem.endsWith(u8, footer, newline));
}
