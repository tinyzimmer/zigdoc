const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Ast = std.zig.Ast;
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
    InvalidZonFile,
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

zig_executable: []const u8 = "zig",
zig_cache_dir: []const u8 = "",

pub fn init(zig_executable: []const u8, zig_cache_dir: []const u8) Self {
    return .{ .zig_executable = zig_executable, .zig_cache_dir = zig_cache_dir };
}

const build_docs_file = @embedFile("build.docs.zig");
const docs_build_dir = "zig-out/zigdocs";

/// Build the documentation for the repository. The allocator of the repository
/// is used to allocate memory for the documentation build.
pub fn build(self: Self, repo: *GitRepo) !Manifest {
    // First check for any dependencies that need to be fetched.
    doc_log.debug("Fetching dependencies for module", .{});
    self.fetchDependencies(repo) catch |err| {
        doc_log.err("Failed to fetch dependencies for module: {any}", .{err});
        return err;
    };

    doc_log.debug("Building documentation for module", .{});

    try repo.writeFile("build.docs.zig", build_docs_file);

    var args = ArrayList([]const u8).init(repo.allocator);
    defer args.deinit();
    try args.append(self.zig_executable);
    try args.append("build");
    if (self.zig_cache_dir.len != 0) {
        try args.append("--global-cache-dir");
        try args.append(self.zig_cache_dir);
    }
    try args.append("--build-file");
    try args.append("build.docs.zig");
    try args.append("zigdocs");

    const result = ChildProcess.run(.{
        .allocator = repo.allocator,
        .argv = args.items,
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

fn fetchDependencies(self: Self, repo: *GitRepo) !void {
    const urls = self.getDependencyURLs(repo) catch {
        // Don't make this fatal, just let getDependencyURLs log the error.
        return;
    };
    if (urls != null) {
        defer urls.?.deinit();
        for (urls.?.items) |url| {
            defer repo.allocator.free(url);
            // Ignore the hash part of the URL.
            var parts = std.mem.splitSequence(u8, url, "#");
            const dep_url = parts.next() orelse continue;
            self.fetchDependency(repo, dep_url) catch {
                // Don't make this fatal, just let fetchDependency log the error.
                continue;
            };
        }
    }
}

fn fetchDependency(self: Self, repo: *GitRepo, url: []const u8) !void {
    var args = ArrayList([]const u8).init(repo.allocator);
    defer args.deinit();

    doc_log.debug("Fetching dependency: {s}", .{url});

    try args.append(self.zig_executable);
    try args.append("fetch");
    if (self.zig_cache_dir.len != 0) {
        try args.append("--global-cache-dir");
        try args.append(self.zig_cache_dir);
    }
    try args.append(url);

    const result = ChildProcess.run(.{
        .allocator = repo.allocator,
        .argv = args.items,
        .cwd = repo.path,
    }) catch {
        return DocsError.ZigNotInstalled;
    };
    defer repo.allocator.free(result.stdout);
    defer repo.allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                doc_log.err("Failed to fetch dependency: exit code: {d} stderr: {s}", .{ code, result.stderr });
                return DocsError.AbnormalExit;
            }
        },
        else => return DocsError.AbnormalExit,
    }
}

fn getDependencyURLs(self: Self, repo: *GitRepo) DocsError!?std.ArrayList([]u8) {
    const zon_file = repo.dir.readFileAllocOptions(
        repo.allocator,
        "build.zig.zon",
        1 * 1024 * 1024,
        null,
        8,
        0,
    ) catch |err| {
        switch (err) {
            Dir.OpenError.FileNotFound => {
                doc_log.debug("Repository does not contain a build.zig.zon file", .{});
                return null;
            },
            else => {
                doc_log.err("Failed to read build.zig.zon file: {any}", .{err});
                return DocsError.FilesystemError;
            },
        }
    };
    defer repo.allocator.free(zon_file);
    var ast = Ast.parse(repo.allocator, zon_file, .zon) catch |err| {
        doc_log.err("Failed to parse build.zig.zon file: {any}", .{err});
        return DocsError.InvalidZonFile;
    };
    defer ast.deinit(repo.allocator);
    return self.dependenciesFromZonAst(repo, ast);
}

fn dependenciesFromZonAst(self: Self, repo: *GitRepo, ast: Ast) DocsError!?std.ArrayList([]u8) {
    const node_tags = ast.nodes.items(.tag);
    const node_datas = ast.nodes.items(.data);
    if (node_tags[0] != .root) {
        return DocsError.InvalidZonFile;
    }
    const main_node_index = node_datas[0].lhs;

    var buf: [2]Ast.Node.Index = undefined;
    const struct_init = ast.fullStructInit(&buf, main_node_index) orelse {
        return DocsError.InvalidZonFile;
    };
    for (struct_init.ast.fields) |field_init| {
        const name_token = ast.firstToken(field_init) - 2;
        const field_name = ast.tokenSlice(name_token);
        if (std.mem.eql(u8, field_name, "dependencies")) {
            return try self.parseDependencies(repo, ast, field_init);
        }
    }
    return null;
}

fn parseDependencies(self: Self, repo: *GitRepo, ast: Ast, node: Ast.Node.Index) DocsError!?std.ArrayList([]u8) {
    var buf: [2]Ast.Node.Index = undefined;
    const struct_init = ast.fullStructInit(&buf, node) orelse {
        return DocsError.InvalidZonFile;
    };
    var urls = std.ArrayList([]u8).init(repo.allocator);
    for (struct_init.ast.fields) |field_init| {
        // const name_token = ast.firstToken(field_init) - 2;
        // const dep_name = ast.tokenSlice(name_token);
        const dep_url = try self.parseDependencyURL(ast, field_init);
        if (dep_url != null) {
            // Trim leading and trailing quotes.
            const trimmed = std.mem.trim(u8, dep_url.?, "\"");
            // Make a copy of the URL so it can be stored in the list.
            var url = repo.allocator.alloc(u8, trimmed.len) catch {
                return DocsError.OutOfMemory;
            };
            errdefer repo.allocator.free(url);
            @memcpy(url[0..], trimmed);
            urls.append(url) catch {
                return DocsError.OutOfMemory;
            };
        }
    }
    return urls;
}

fn parseDependencyURL(_: Self, ast: Ast, node: Ast.Node.Index) DocsError!?[]const u8 {
    var buf: [2]Ast.Node.Index = undefined;
    const struct_init = ast.fullStructInit(&buf, node) orelse {
        return DocsError.InvalidZonFile;
    };
    for (struct_init.ast.fields) |field_init| {
        const name_token = ast.firstToken(field_init) - 2;
        const field_name = ast.tokenSlice(name_token);
        if (std.mem.eql(u8, field_name, "url")) {
            const node_tags = ast.nodes.items(.tag);
            const main_tokens = ast.nodes.items(.main_token);
            if (node_tags[field_init] != .string_literal) {
                return DocsError.InvalidZonFile;
            }
            const str_lit_token = main_tokens[field_init];
            const value = ast.tokenSlice(str_lit_token);
            return value;
        }
    }
    return null;
}
