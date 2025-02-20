const std = @import("std");
const Allocator = std.mem.Allocator;
const ChildProcess = std.process.Child;
const EnvMap = std.process.EnvMap;

const GitError = @import("errors.zig").GitError;

const git_log = std.log.scoped(.git);

allocator: Allocator,
tag: []const u8,
commit: []const u8,

pub const Self = @This();

/// Lookup the latest tag for a given repository. If no tags exist, the default branch and latest commit hash are returned.
pub fn fetchLatestTag(allocator: Allocator, git_executable: []const u8, repository: []const u8) GitError!Self {
    return getLatestTag(allocator, git_executable, repository);
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.tag);
    self.allocator.free(self.commit);
}

fn getLatestTag(allocator: Allocator, git_executable: []const u8, repository: []const u8) GitError!Self {
    const repo = std.fmt.allocPrint(allocator, "https://{s}", .{repository}) catch {
        return GitError.OutOfMemory;
    };
    defer allocator.free(repo);

    var env_map = EnvMap.init(allocator);
    defer env_map.deinit();

    const result = ChildProcess.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            git_executable, "-c",     "versionsort.suffix=-",
            "ls-remote",    "--tags", "--sort=-v:refname",
            repo,
        },
        .env_map = &env_map,
    }) catch {
        return GitError.GitNotInstalled;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                if (code == 128) {
                    git_log.warn("Repository not found: {s}", .{repo});
                    return GitError.NotFound;
                }
                git_log.err("Failed to get latest tag: exit code: {d} stderr: {s}", .{ code, result.stderr });
                return GitError.AbnormalExit;
            }
        },
        else => return GitError.AbnormalExit,
    }

    if (result.stdout.len == 0) {
        // Lookup the default branch and latest commit hash
        return getDefaultBranch(allocator, git_executable, repo);
    }

    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    while (lines.next()) |latest| {
        if (latest.len == 0) {
            // We probably hit the end of the list
            continue;
        }
        var parts = std.mem.splitSequence(u8, latest, "\t");
        const commit = parts.next() orelse {
            git_log.warn("Failed to parse commit hash: {s}", .{latest});
            continue;
        };
        const tagref = parts.next() orelse {
            git_log.warn("Failed to parse tag reference: {s}", .{latest});
            continue;
        };
        const tag = std.mem.trimLeft(u8, tagref, "refs/tags/");

        if (!isValidTag(tag)) {
            continue;
        }

        var outtag = allocator.alloc(u8, tag.len) catch {
            return GitError.OutOfMemory;
        };
        errdefer allocator.free(outtag);
        @memcpy(outtag[0..], tag);
        var outcommit = allocator.alloc(u8, commit.len) catch {
            return GitError.OutOfMemory;
        };
        @memcpy(outcommit[0..], commit);

        return .{ .allocator = allocator, .tag = outtag, .commit = outcommit };
    }

    // None of the tags were valid, fall back to default branch
    return getDefaultBranch(allocator, git_executable, repo);
}

fn isValidTag(tag: []const u8) bool {
    if (std.mem.startsWith(u8, tag, "v")) return true;
    // Check if the first character is a digit
    if (tag[0] >= '0' and tag[0] <= '9') return true;
    return false;
}

fn getDefaultBranch(allocator: Allocator, git_executable: []const u8, repository_url: []const u8) GitError!Self {
    var env_map = EnvMap.init(allocator);
    defer env_map.deinit();
    const result = ChildProcess.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            git_executable, "ls-remote", "--symref", repository_url,
        },
        .env_map = &env_map,
    }) catch {
        return GitError.GitNotInstalled;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                if (code == 128) {
                    git_log.warn("Repository not found: {s}", .{repository_url});
                    return GitError.NotFound;
                }
                git_log.err("Failed to get default branch: exit code: {d} stderr: {s}", .{ code, result.stderr });
                return GitError.AbnormalExit;
            }
        },
        else => return GitError.AbnormalExit,
    }

    var lines = std.mem.splitSequence(u8, result.stdout, "\n");
    const ref_info = lines.next() orelse return GitError.AbnormalReference;
    const commit_info = lines.next() orelse return GitError.AbnormalReference;

    const ref = std.mem.trimRight(
        u8,
        std.mem.trimLeft(u8, ref_info, "ref: refs/heads/"),
        "\tHEAD",
    );
    const commit = std.mem.trimRight(u8, commit_info, "\tHEAD");

    var outtag = allocator.alloc(u8, ref.len) catch {
        return GitError.OutOfMemory;
    };
    @memcpy(outtag[0..], ref);
    var outcommit = allocator.alloc(u8, commit.len) catch {
        return GitError.OutOfMemory;
    };
    @memcpy(outcommit[0..], commit);

    return .{ .allocator = allocator, .tag = outtag, .commit = outcommit };
}
