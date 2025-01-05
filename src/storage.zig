const std = @import("std");
const httpz = @import("httpz");

const Allocator = std.mem.Allocator;

pub const Buffer = @import("storage/buffer.zig");
pub const StorageError = @import("storage/errors.zig").StorageError;
const LocalDir = @import("storage/localdir.zig");
const Manifest = @import("docs.zig").Manifest;
const RemoteSource = @import("remotesource.zig");
const VersionLatest = RemoteSource.VersionLatest;

const storage_log = std.log.scoped(.storage);

allocator: Allocator,
provider: union(enum) {
    local_dir: LocalDir,
},

const Self = @This();

pub fn initLocalDir(allocator: Allocator, path: []const u8) !Self {
    const dir = std.fs.cwd().openDir(".", .{
        .access_sub_paths = true,
        .iterate = true,
    }) catch {
        return StorageError.FilesystemError;
    };
    return .{
        .allocator = allocator,
        .provider = .{
            .local_dir = LocalDir.init(allocator, dir, path),
        },
    };
}

pub fn deinit(self: *Self) void {
    switch (self.provider) {
        inline else => |impl| return impl.deinit(),
    }
}

pub fn openManifest(self: *Self, location: RemoteSource) !Manifest {
    switch (self.provider) {
        inline else => |impl| return impl.openManifest(location),
    }
}

pub fn writeManifest(self: *Self, location: RemoteSource, manifest: Manifest) !void {
    switch (self.provider) {
        inline else => |impl| return impl.writeManifest(location, manifest),
    }
}

pub fn linkLatest(self: *Self, location: RemoteSource) !void {
    switch (self.provider) {
        inline else => |impl| return impl.linkLatest(location),
    }
}
