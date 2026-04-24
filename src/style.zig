const std = @import("std");

pub const Kind = enum {
    title,
    header,
    dim,
    selected,
    league,
    up,
    live,
    final,
    postponed,
    time,
    network,
    footer,
    err,
};

const reset = "\x1b[0m";

fn code(kind: Kind) []const u8 {
    return switch (kind) {
        .title => "\x1b[1m",
        .header => "\x1b[1;36m",
        .dim => "\x1b[2m",
        .selected => "\x1b[1;32m",
        .league => "\x1b[36m",
        .up => "\x1b[34m",
        .live => "\x1b[1;32m",
        .final => "\x1b[2m",
        .postponed => "\x1b[33m",
        .time => "\x1b[33m",
        .network => "\x1b[35m",
        .footer => "\x1b[2m",
        .err => "\x1b[1;31m",
    };
}

pub fn write(w: *std.Io.Writer, enabled: bool, kind: Kind, value: []const u8) !void {
    if (enabled) try w.writeAll(code(kind));
    try w.writeAll(value);
    if (enabled) try w.writeAll(reset);
}

pub fn writeCell(w: *std.Io.Writer, enabled: bool, kind: Kind, value: []const u8, width: usize) !void {
    const n = @min(value.len, width);
    if (enabled) try w.writeAll(code(kind));
    try w.writeAll(value[0..n]);
    if (enabled) try w.writeAll(reset);
    var spaces = width - n;
    while (spaces > 0) : (spaces -= 1) try w.writeByte(' ');
}

pub fn resetAll(w: *std.Io.Writer, enabled: bool) !void {
    if (enabled) try w.writeAll(reset);
}
