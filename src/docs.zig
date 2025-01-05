const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const ChildProcess = std.process.Child;
const Dir = std.fs.Dir;

const GitRepo = @import("git/repository.zig");

const doc_log = std.log.scoped(.docs);

const Self = @This();

pub const DocsError = error{
    ZigNotInstalled,
    FilesystemError,
    AbnormalExit,
    OutOfMemory,
};

/// Manifest of the documentation build.
pub const Manifest = struct {
    __allocator: Allocator,
    __unmanaged_keys: bool = false,
    /// A list of directories containing the documentation
    /// that was built for each module. The basename of the
    /// directory is the module name.
    modules: StringHashMap(Dir),

    /// Initialize the manifest with the given allocator and modules.
    /// It is assumed that the allocator was used to allocate the
    /// keys in the `modules` hashmap. If that is not the case, use
    /// `initUnmanaged`.
    pub fn init(allocator: Allocator, modules: StringHashMap(Dir)) Manifest {
        return .{ .__allocator = allocator, .modules = modules };
    }

    pub fn initUnmanaged(allocator: Allocator, modules: StringHashMap(Dir)) Manifest {
        return .{ .__allocator = allocator, .__unmanaged_keys = true, .modules = modules };
    }

    /// Deallocate the resources associated with the manifest.
    /// The directories in the manifest are closed.
    pub fn deinit(self: *Manifest) void {
        var it = self.modules.iterator();
        while (it.next()) |kv| {
            if (!self.__unmanaged_keys) self.__allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.close();
        }
        self.modules.deinit();
    }
};

const build_docs_file = @embedFile("build.docs.zig");

const docs_build_dir = "zig-out/zigdocs";

/// Build the documentation for the repository. The allocator of the repository
/// is used to allocate memory for the documentation build.
pub fn build(repo: *GitRepo) !Manifest {
    try repo.writeFile("build.docs.zig", build_docs_file);
    const result = ChildProcess.run(.{
        .allocator = repo.allocator,
        .argv = &[_][]const u8{
            "zig",          "build",
            "--build-file", "build.docs.zig",
            "zigdocs",
        },
        .cwd = repo.path,
    }) catch {
        return DocsError.ZigNotInstalled;
    };
    defer repo.allocator.free(result.stdout);
    defer repo.allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                doc_log.err("Failed to build documentation: exit code: {d} stderr: {s}", .{ code, result.stderr });
                return DocsError.AbnormalExit;
            }
        },
        else => return DocsError.AbnormalExit,
    }

    var dir = repo.dir.openDir(docs_build_dir, .{
        .iterate = true,
        .access_sub_paths = true,
    }) catch {
        return DocsError.FilesystemError;
    };
    defer dir.close();

    var modules = StringHashMap(Dir).init(repo.allocator);

    var it = dir.iterate();
    while (it.next() catch {
        return DocsError.FilesystemError;
    }) |entry| {
        if (entry.kind == .directory) {
            doc_log.debug("Found generated module documentation at '" ++ docs_build_dir ++ "/{s}'", .{entry.name});
            var key = repo.allocator.alloc(u8, entry.name.len) catch {
                return DocsError.OutOfMemory;
            };
            @memcpy(key[0..], entry.name);
            const mod_docs = dir.openDir(entry.name, .{
                .iterate = true,
                .access_sub_paths = true,
            }) catch {
                return DocsError.FilesystemError;
            };
            modules.put(key, mod_docs) catch {
                return DocsError.OutOfMemory;
            };
        }
    }

    return Manifest.init(repo.allocator, modules);
}
