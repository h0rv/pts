const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "pts",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run pts");
    run_step.dependOn(&run_cmd.step);

    const parser_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/parser_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser_tests_mod.addImport("parser", b.createModule(.{ .root_source_file = b.path("src/parser.zig") }));

    const parser_tests = b.addTest(.{
        .root_module = parser_tests_mod,
    });
    const run_parser_tests = b.addRunArtifact(parser_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_parser_tests.step);
}
