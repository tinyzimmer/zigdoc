const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;
const File = std.fs.File;
const ReadLinkError = std.posix.ReadLinkError;
const StringHashMap = std.StringHashMap;

const Buffer = @import("buffer.zig");
const RemoteSource = @import("../remotesource.zig");
const Manifest = @import("../docs.zig").Manifest;

const StorageError = @import("errors.zig").StorageError;
const VersionLatest = RemoteSource.VersionLatest;

const local_dir_log = std.log.scoped(.local_dir);

const max_manifest_size = 1 * 1024 * 1024; // 1MB

const Self = @This();

allocator: Allocator,
cwd: Dir,
root: []const u8,

pub fn init(allocator: Allocator, cwd: Dir, root: []const u8) Self {
    return .{
        .allocator = allocator,
        .cwd = cwd,
        .root = root,
    };
}

pub fn deinit(self: Self) void {
    var d = self.cwd;
    d.close();
}

pub fn openManifest(self: Self, location: RemoteSource) StorageError!Manifest {
    var dir = try self.getRepoDirHandle(location);
    defer dir.close();
    var modules = StringHashMap(Dir).init(self.allocator);
    var it = dir.iterate();
    while (it.next() catch {
        return StorageError.StorageReadFailed;
    }) |entry| {
        if (entry.kind == .directory) {
            local_dir_log.debug("Found saved module documentation for {s}", .{entry.name});
            var key = self.allocator.alloc(u8, entry.name.len) catch {
                return StorageError.OutOfMemory;
            };
            @memcpy(key[0..], entry.name);
            const mod_docs = dir.openDir(entry.name, .{
                .iterate = true,
                .access_sub_paths = true,
            }) catch {
                return StorageError.FilesystemError;
            };
            modules.put(key, mod_docs) catch {
                return StorageError.OutOfMemory;
            };
        }
    }
    return Manifest.init(self.allocator, modules);
}

pub fn writeManifest(self: Self, location: RemoteSource, manifest: Manifest) !void {
    var dir = self.getRepoDirHandle(location) catch |err| {
        switch (err) {
            StorageError.StorageNotFound => {
                const modpath = try self.getRepoPath(location);
                defer self.allocator.free(modpath);
                self.cwd.makePath(modpath) catch {
                    return StorageError.StorageWriteFailed;
                };
                return self.writeManifest(location, manifest);
            },
            else => return err,
        }
    };
    defer dir.close();

    var it = manifest.modules.iterator();
    while (it.next()) |kv| {
        const module_name = kv.key_ptr.*;
        const build_dir = kv.value_ptr.*;
        local_dir_log.debug("Writing module documentation for {s}", .{module_name});
        dir.makePath(module_name) catch {
            return StorageError.StorageWriteFailed;
        };
        var module_dir = dir.openDir(module_name, .{
            .access_sub_paths = true,
            .iterate = true,
        }) catch {
            return StorageError.StorageReadFailed;
        };
        defer module_dir.close();
        var walker = build_dir.walk(self.allocator) catch {
            return StorageError.StorageReadFailed;
        };
        defer walker.deinit();
        while (try walker.next()) |entry| {
            Dir.copyFile(build_dir, entry.path, module_dir, entry.basename, .{}) catch {
                return StorageError.StorageWriteFailed;
            };
        }
    }
}

pub fn linkLatest(self: Self, location: RemoteSource) StorageError!void {
    const root_path = try self.getRepoPath(location);
    defer self.allocator.free(root_path);
    self.cwd.makePath(root_path) catch {
        return StorageError.InvalidStoragePath;
    };
    const link_path = try self.getLatestLinkPath(location);
    defer self.allocator.free(link_path);
    local_dir_log.debug("Linking latest {s} => {s}", .{ link_path, location.version });
    self.cwd.symLink(location.version, link_path, .{ .is_directory = true }) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {
                self.cwd.deleteFile(link_path) catch |rmerr| {
                    local_dir_log.err("Failed to remove existing link: {}", .{rmerr});
                    return StorageError.StorageWriteFailed;
                };
                self.cwd.symLink(location.version, link_path, .{ .is_directory = true }) catch |lerr| {
                    local_dir_log.err("Failed to link latest: {}", .{lerr});
                    return StorageError.StorageWriteFailed;
                };
            },
            else => return StorageError.StorageWriteFailed,
        }
    };
}

fn getRepoDirHandle(self: Self, location: RemoteSource) StorageError!Dir {
    const dir_path = try self.getRepoPath(location);
    defer self.allocator.free(dir_path);
    return self.cwd.openDir(dir_path, .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch |err| {
        if (err == Dir.OpenError.FileNotFound) {
            return StorageError.StorageNotFound;
        }
        local_dir_log.err("Failed to open directory: {}", .{StorageError.StorageReadFailed});
        return StorageError.StorageReadFailed;
    };
}

fn getRepoPath(self: Self, location: RemoteSource) StorageError![]const u8 {
    return std.fs.path.join(self.allocator, &.{
        self.root,
        location.repository,
        location.version,
    }) catch |err| {
        local_dir_log.err("Failed to join path: {}", .{err});
        return StorageError.OutOfMemory;
    };
}

fn getLatestLinkPath(self: Self, location: RemoteSource) StorageError![]const u8 {
    return std.fs.path.join(self.allocator, &.{
        self.root,
        location.repository,
        VersionLatest,
    }) catch |err| {
        local_dir_log.err("Failed to join path: {}", .{err});
        return StorageError.OutOfMemory;
    };
}
