const std = @import("std");

const Allocator = std.mem.Allocator;

const Repository = @import("repository.zig");
const RepositoryError = Repository.RepositoryError;
const RemoteSource = @import("remotesource.zig");
const storage = @import("storage.zig");

const Buffer = storage.Buffer;
const VersionLatest = RemoteSource.VersionLatest;

const service_log = std.log.scoped(.service);

repo: *Repository,

const Self = @This();

pub const ServiceError = error{
    ModuleNotFound,
    QueuedManifestSync,
    UnrecogizedFileExtension,
};

pub fn init(repo: *Repository) Self {
    return .{ .repo = repo };
}

pub fn checkDocsManifestPopulated(self: *Self, repo_location: RemoteSource) !bool {
    service_log.debug("Checking documentation manifest for {s}@{s}", .{ repo_location.repository, repo_location.version });
    return try self.repo.checkDocsManifestPopulated(repo_location);
}

pub fn getModulesList(self: *Self, allocator: Allocator, source: RemoteSource) ![]const []const u8 {
    service_log.debug("Retrieving docs manifest for repository: {s} version: {s} module: {s} file {s}", .{
        source.repository,
        source.version,
        source.module,
        source.file,
    });
    var manifest = self.repo.getDocsManifest(source) catch |err| {
        switch (err) {
            RepositoryError.QueuedManifestSync => {
                return ServiceError.QueuedManifestSync;
            },
            else => return err,
        }
    };
    defer manifest.deinit();
    var keys = manifest.modules.keyIterator();
    var arr = std.ArrayList([]const u8).init(allocator);
    defer arr.deinit();
    while (keys.next()) |key| {
        var module_name = try allocator.alloc(u8, key.len);
        @memcpy(module_name[0..], key.*);
        try arr.append(module_name);
    }
    return arr.toOwnedSlice();
}

pub fn getDocsResource(self: *Self, _: Allocator, source: RemoteSource) !Buffer {
    service_log.debug("Retrieving docs for repository: {s} version: {s} module: {s} file {s}", .{
        source.repository,
        source.version,
        source.module,
        source.file,
    });
    var manifest = self.repo.getDocsManifest(source) catch |err| {
        switch (err) {
            RepositoryError.QueuedManifestSync => {
                return ServiceError.QueuedManifestSync;
            },
            else => return err,
        }
    };
    defer manifest.deinit();
    // Return the requested file
    const module = manifest.modules.get(source.module) orelse return ServiceError.ModuleNotFound;
    const file = try module.openFile(source.file, .{ .mode = .read_only });
    const file_ext = std.fs.path.extension(source.file);
    if (file_ext.len == 0) {
        return ServiceError.UnrecogizedFileExtension;
    }
    const supported_exts = enum { html, md, wasm, js, css, tar };
    const ext = std.meta.stringToEnum(supported_exts, file_ext[1..]) orelse {
        return ServiceError.UnrecogizedFileExtension;
    };
    return Buffer.initFile(file, switch (ext) {
        .html => "text/html",
        .md => "text/markdown",
        .wasm => "application/wasm",
        .js => "application/javascript",
        .css => "text/css",
        .tar => "application/x-tar",
    });
}
