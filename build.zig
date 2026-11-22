const std = @import("std");

pub fn build(b: *std.Build) void {
    const compiler = b.addExecutable(.{
        .name = "gwbc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ziggify/compiler.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    b.installArtifact(compiler);
}
