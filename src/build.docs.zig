const std = @import("std");

const projectbuild = @import("build.zig");

pub fn build(b: *std.Build) void {
    const buildFunc: fn (*std.Build) void = comptime blk: {
        var canError: bool = true;
        if (@typeInfo(@TypeOf(projectbuild.build)).@"fn".return_type.? == void) {
            canError = false;
        }
        if (canError) {
            break :blk tryBuild;
        } else {
            break :blk projectbuild.build;
        }
    };

    buildFunc(b);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const docs_step = b.step("zigdocs", "Install docs into zig-out/docs");

    var mods = b.modules.iterator();
    while (mods.next()) |modvalue| {
        const module = modvalue.value_ptr.*;
        const name = modvalue.key_ptr.*;
        module.resolved_target = b.graph.host;
        const lib = b.addStaticLibrary(.{
            .name = name,
            .root_module = module,
        });
        const install_docs = b.addInstallDirectory(.{
            .source_dir = lib.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = std.fmt.allocPrint(allocator, "zigdocs/{s}", .{name}) catch {
                return;
            },
        });
        docs_step.dependOn(&install_docs.step);
    }
}

fn tryBuild(b: *std.Build) void {
    projectbuild.build(b) catch {
        @panic("Failed to run project build");
    };
}
