const std = @import("std");

pub const VersionLatest = "latest";

const DefaultDocsPath = "index.html";

pub const SourceError = error{
    InvalidPath,
    UnsupportedHost,
    OutOfMemory,
};

const Self = @This();

allocator: ?std.mem.Allocator = null,

repository: []const u8,
version: []const u8,
module: []const u8,
file: []const u8,

pub fn parse(allocator: std.mem.Allocator, path: []const u8) SourceError!Self {
    // Check for directory traversal
    try checkDirTraversal(path);

    // Walk the path by segment to determine the repository, version, and any subsequent path
    var repo_parts = std.mem.splitSequence(u8, path, "/");

    var repository = std.ArrayList(u8).init(allocator);
    var version = std.ArrayList(u8).init(allocator);
    var module = std.ArrayList(u8).init(allocator);
    var file = std.ArrayList(u8).init(allocator);

    errdefer repository.deinit();
    errdefer version.deinit();
    errdefer module.deinit();
    errdefer file.deinit();

    const hostname = repo_parts.next() orelse return SourceError.InvalidPath;
    const SupportedHosts = enum {
        @"github.com",
        @"gitlab.com",
    };
    const host = std.meta.stringToEnum(SupportedHosts, hostname) orelse return SourceError.UnsupportedHost;
    switch (host) {
        .@"github.com", .@"gitlab.com" => {
            std.fmt.format(repository.writer(), "{s}/", .{hostname}) catch return SourceError.OutOfMemory;
            const org = repo_parts.next() orelse return SourceError.InvalidPath;
            const repo = repo_parts.next() orelse return SourceError.InvalidPath;
            // Here we may have a version identifier
            var versioned = std.mem.splitSequence(u8, repo, "@");
            const unversioned_repo = versioned.next() orelse return SourceError.InvalidPath;
            const n = try version.writer().write(versioned.rest());
            if (n == 0) {
                _ = try version.writer().write(VersionLatest);
            }
            std.fmt.format(repository.writer(), "{s}/{s}", .{ org, unversioned_repo }) catch return SourceError.OutOfMemory;
            // Next is the module
            const module_path = repo_parts.next() orelse {
                _ = try file.writer().write(DefaultDocsPath);
                return .{
                    .allocator = allocator,
                    .repository = repository.toOwnedSlice() catch return SourceError.OutOfMemory,
                    .version = version.toOwnedSlice() catch return SourceError.OutOfMemory,
                    .module = module.toOwnedSlice() catch return SourceError.OutOfMemory,
                    .file = file.toOwnedSlice() catch return SourceError.OutOfMemory,
                };
            };
            _ = try module.writer().write(module_path);
            // Anything left is the file
            const rest = repo_parts.rest();
            if (rest.len == 0) {
                _ = try file.writer().write(DefaultDocsPath);
            } else {
                _ = try file.writer().write(rest);
            }
        },
    }

    return .{
        .allocator = allocator,
        .repository = repository.toOwnedSlice() catch return SourceError.OutOfMemory,
        .version = version.toOwnedSlice() catch return SourceError.OutOfMemory,
        .module = module.toOwnedSlice() catch return SourceError.OutOfMemory,
        .file = file.toOwnedSlice() catch return SourceError.OutOfMemory,
    };
}

fn checkDirTraversal(path: []const u8) SourceError!void {
    if (std.mem.containsAtLeast(u8, path, 1, "..")) {
        return SourceError.InvalidPath;
    }
}

pub fn deinit(self: *Self) void {
    if (self.allocator != null) {
        self.allocator.?.free(self.repository);
        self.allocator.?.free(self.version);
        self.allocator.?.free(self.module);
        self.allocator.?.free(self.file);
    }
}

pub fn shallowClone(self: *Self) Self {
    return .{
        .allocator = self.allocator,
        .repository = self.repository,
        .version = self.version,
        .module = self.module,
        .file = self.file,
    };
}

pub fn shallowCloneWithVersion(self: *Self, version: []const u8) Self {
    return .{
        .allocator = self.allocator,
        .repository = self.repository,
        .version = version,
        .module = self.module,
        .file = self.file,
    };
}

pub fn clone(self: *Self, allocator: std.mem.Allocator, version_override: ?[]const u8) !Self {
    var repo = try allocator.alloc(u8, self.repository.len);
    errdefer allocator.free(repo);
    var module = try allocator.alloc(u8, self.module.len);
    errdefer allocator.free(module);
    var file = try allocator.alloc(u8, self.file.len);
    errdefer allocator.free(file);
    @memcpy(repo[0..], self.repository);
    @memcpy(module[0..], self.module);
    @memcpy(file[0..], self.file);
    if (version_override != null) {
        var version = try allocator.alloc(u8, version_override.?.len);
        @memcpy(version[0..], version_override.?);
        return .{
            .allocator = allocator,
            .repository = repo,
            .version = version,
            .module = module,
            .file = file,
        };
    }
    var version = try allocator.alloc(u8, self.version.len);
    @memcpy(version[0..], self.version);
    return .{
        .allocator = allocator,
        .repository = repo,
        .version = version,
        .module = module,
        .file = file,
    };
}

test "RemoteSource: parse" {
    const allocator = std.testing.allocator;

    const case = struct {
        location: []const u8,
        expected_source: ?Self = null,
        expected_error: ?SourceError = null,
    };

    const test_cases = [_]case{
        .{
            .location = "invalid.com/org/repo",
            .expected_error = SourceError.UnsupportedHost,
        },
        .{
            .location = "github.com/org",
            .expected_error = SourceError.InvalidPath,
        },
        .{
            .location = "github.com/org/repo",
            .expected_source = .{
                .allocator = allocator,
                .repository = "github.com/org/repo",
                .version = "latest",
                .module = "",
                .file = "index.html",
            },
        },
        .{
            .location = "github.com/org/repo/../",
            .expected_error = SourceError.InvalidPath,
        },
        .{
            .location = "github.com/org/repo/module",
            .expected_source = .{
                .allocator = allocator,
                .repository = "github.com/org/repo",
                .version = "latest",
                .module = "module",
                .file = "index.html",
            },
        },
        .{
            .location = "github.com/org/repo/module/main.js",
            .expected_source = .{
                .allocator = allocator,
                .repository = "github.com/org/repo",
                .version = "latest",
                .module = "module",
                .file = "main.js",
            },
        },
        .{
            .location = "github.com/org/repo@v1.0.0/module/main.js",
            .expected_source = .{
                .allocator = allocator,
                .repository = "github.com/org/repo",
                .version = "v1.0.0",
                .module = "module",
                .file = "main.js",
            },
        },
    };

    for (test_cases) |tc| {
        if (tc.expected_error != null) {
            try std.testing.expectError(tc.expected_error.?, Self.parse(allocator, tc.location));
        } else {
            var actual = try Self.parse(allocator, tc.location);
            defer actual.deinit();
            try std.testing.expectEqualDeep(tc.expected_source.?, actual);
        }
    }
}
