const std = @import("std");

const Allocator = std.mem.Allocator;
const ChildProcess = std.process.Child;
const EnvMap = std.process.EnvMap;

const GitError = @import("errors.zig").GitError;

const git_log = std.log.scoped(.git);

allocator: Allocator,
path: []const u8,
dir: std.fs.Dir,
git_executable: []const u8 = "git",

pub const Self = @This();

/// Initialize the git interface with the given allocator and working directory.
pub fn init(allocator: Allocator, git_executable: []const u8, path: []const u8) !Self {
    const dir = std.fs.cwd().openDir(path, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch {
        return GitError.FilesystemError;
    };
    return .{ .allocator = allocator, .path = path, .dir = dir, .git_executable = git_executable };
}

pub fn deinit(self: *Self) void {
    self.dir.close();
}

/// Clone a repository to the working directory.
pub fn clone(self: *Self, repository: []const u8, version: []const u8) GitError!void {
    const repo = std.fmt.allocPrint(self.allocator, "https://{s}", .{repository}) catch {
        return GitError.OutOfMemory;
    };
    defer self.allocator.free(repo);

    var env_map = EnvMap.init(self.allocator);
    defer env_map.deinit();

    const result = ChildProcess.run(.{
        .allocator = self.allocator,
        .argv = &[_][]const u8{
            self.git_executable, "clone", "--depth=1", "--branch", version, repo, ".",
        },
        .cwd = self.path,
        .env_map = &env_map,
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

/// Write a file to the working directory.
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
