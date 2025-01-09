const std = @import("std");
const Allocator = std.mem.Allocator;

const GitError = @import("errors.zig").GitError;
const Repository = @import("repository.zig");
const Tag = @import("tag.zig");

const Self = @This();

git_executable: []const u8 = "git",

pub fn init(git_executable: []const u8) Self {
    return .{ .git_executable = git_executable };
}

pub fn initRepository(self: Self, allocator: Allocator, workdir: []const u8) GitError!Repository {
    return Repository.init(allocator, self.git_executable, workdir);
}

pub fn fetchLatestTag(self: Self, allocator: Allocator, repository: []const u8) GitError!Tag {
    return Tag.fetchLatestTag(allocator, self.git_executable, repository);
}
