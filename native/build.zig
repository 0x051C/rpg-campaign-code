//! The game's native code: the unit registry's core in Zig (src/core, plain Zig, no Godot) and
//! the GDExtension that hands it to GDScript (src/UnitStore.zig, through gdzig).
//!
//!   zig build -Doptimize=ReleaseFast    builds bin/libunits.so for the project
//!   zig build test                      runs the core's tests (no Godot needed)

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gdzig_dep = b.dependency("gdzig", .{ .target = target, .optimize = optimize });
    const extension_module = b.createModule(.{
        .root_source_file = b.path("src/extension.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "godot", .module = gdzig_dep.module("gdzig") },
            .{ .name = "core", .module = core },
        },
    });
    const extension = gdzig.addExtension(b, .{
        .name = "units",
        .root_module = extension_module,
        .entry_symbol = "units_init",
        .target = target,
        .optimize = optimize,
    }) orelse return;
    const install = b.addInstallFileWithDir(extension.output, .{ .custom = "../../bin" }, extension.filename);
    b.default_step.dependOn(&install.step);

    const core_tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run the core's tests").dependOn(&b.addRunArtifact(core_tests).step);
}

const std = @import("std");
const Build = std.Build;
const gdzig = @import("gdzig");
