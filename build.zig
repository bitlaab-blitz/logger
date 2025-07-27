const std = @import("std");
const builtin = @import("builtin");


pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Exposing as a dependency for other projects
    const pkg = b.addModule("logger", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize
    });

    const main = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app = "logger";
    const exe = b.addExecutable(.{.name = app, .root_module = main});

    // Self importing package
    exe.root_module.addImport("logger", pkg);

    // // External package dependencies
    // const jsonic = b.dependency("jsonic", .{});
    // pkg.addImport("jsonic", jsonic.module("jsonic"));
    // exe.root_module.addImport("jsonic", jsonic.module("jsonic"));

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
