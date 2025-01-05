const std = @import("std");

const Allocator = std.mem.Allocator;
const ChildProcess = std.process.Child;

const GitError = @import("errors.zig").GitError;

const git_log = std.log.scoped(.git);

allocator: Allocator,
path: []const u8,
dir: std.fs.Dir,

pub const Self = @This();

pub fn init(allocator: Allocator, path: []const u8) !Self {
    const dir = std.fs.cwd().openDir(path, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch {
        return GitError.FilesystemError;
    };
    return .{ .allocator = allocator, .path = path, .dir = dir };
}

pub fn deinit(self: *Self) void {
    self.dir.close();
}

pub fn clone(self: *Self, repository: []const u8, version: []const u8) GitError!void {
    const repo = std.fmt.allocPrint(self.allocator, "https://{s}", .{repository}) catch {
        return GitError.OutOfMemory;
    };
    defer self.allocator.free(repo);

    const result = ChildProcess.run(.{
        .allocator = self.allocator,
        .argv = &[_][]const u8{
            "git", "clone", "--depth=1", "--branch", version, repo, ".",
        },
        .cwd = self.path,
    }) catch {
        return GitError.GitNotInstalled;
    };
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                if (code == 128) {
                    git_log.warn("Repository not found: {s}", .{repository});
                    return GitError.NotFound;
                }
                git_log.err("Failed to clone repository: exit code: {d} stderr: {s}", .{ code, result.stderr });
                return GitError.AbnormalExit;
            }
        },
        else => return GitError.AbnormalExit,
    }
}

pub fn writeFile(self: *Self, path: []const u8, contents: []const u8) GitError!void {
    const file = self.dir.createFile(path, .{
        .exclusive = true,
    }) catch {
        return GitError.FilesystemError;
    };
    defer file.close();

    file.writeAll(contents) catch {
        return GitError.FilesystemError;
    };
}
