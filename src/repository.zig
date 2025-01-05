//! This module provides functions for retrieving documentation from the storage backend.
//! If the storage backend does not have documentation for the requested package@version
//! yet, a WorkerPool is used to run synchronization jobs.

const std = @import("std");
const Allocator = std.mem.Allocator;

const WorkerPool = @import("workerpool.zig");
const Job = WorkerPool.Job;
const WorkerError = WorkerPool.WorkerError;

const Storage = @import("storage.zig");
const TempDir = @import("storage/temp.zig").TempDir;

const StorageError = Storage.StorageError;
const Buffer = Storage.Buffer;

const RemoteSource = @import("remotesource.zig");
const VersionLatest = RemoteSource.VersionLatest;

const Git = @import("git/git.zig");
const Manifest = @import("docs.zig").Manifest;

const Docs = @import("docs.zig");

const repo_log = std.log.scoped(.repository);

/// The underlying memory allocator.
allocator: Allocator,
/// The backing storage implementation.
store: *Storage,
/// The documentation builder
builder: Docs,
// Interface for working with git
git: Git,
/// The worker pool for running documentation build jobs.
worker_pool: WorkerPool,

const Self = @This();

pub const RepositoryError = error{
    QueuedManifestSync,
};

pub fn init(allocator: Allocator, store: *Storage, builder: Docs, git: Git) Self {
    return .{
        .allocator = allocator,
        .store = store,
        .builder = builder,
        .git = git,
        .worker_pool = WorkerPool.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.worker_pool.deinit();
}

pub fn getDocsManifest(self: *Self, repo_location: RemoteSource) !Manifest {
    var loc = repo_location;
    repo_log.debug("Fetching documentation manifest for {s}@{s}", .{ loc.repository, loc.version });
    return self.store.openManifest(loc) catch |err| {
        switch (err) {
            StorageError.StorageNotFound => {
                repo_log.info("No documentation found for {s}@{s}, running sync job", .{ loc.repository, loc.version });
                var job = Job.init(
                    try loc.clone(self.allocator, loc.version),
                    if (std.mem.eql(u8, loc.version, VersionLatest)) .SyncLatest else .SyncRepository,
                );
                self.worker_pool.addJob(
                    job,
                    Self.runJob,
                    .{ self, job },
                ) catch |qerr| {
                    job.deinit();
                    repo_log.err("Failed to queue job for: {s}@{s}: {any}", .{
                        loc.repository,
                        loc.version,
                        qerr,
                    });
                    return qerr;
                };
                return RepositoryError.QueuedManifestSync;
            },
            else => return err,
        }
    };
}

pub fn checkDocsManifestPopulated(self: *Self, repo_location: RemoteSource) !bool {
    repo_log.debug("Checking documentation manifest for {s}@{s}", .{ repo_location.repository, repo_location.version });
    var manifest = try self.store.openManifest(repo_location);
    defer manifest.deinit();
    return manifest.modules.count() > 0;
}

fn runJob(self: *Self, job: Job) void {
    var j = job;
    defer j.deinit();
    defer self.worker_pool.completeJob(job);

    switch (job.job_type) {
        .SyncLatest => self.syncLatest(job.location),
        .SyncRepository => self.syncRepositoryDocs(job.location),
    }
}

fn syncLatest(self: *Self, location: RemoteSource) void {
    var loc = location;

    repo_log.info("Fetching latest tag or commit for {s}@{s}", .{
        location.repository,
        location.version,
    });

    var tag = self.git.fetchLatestTag(self.allocator, loc.repository) catch |err| {
        repo_log.err("Failed to fetch latest tag for: {s}: {any}", .{ loc.repository, err });
        return;
    };
    defer tag.deinit();
    repo_log.debug("Latest tag/branch for {s}: {s}\t{s}", .{ loc.repository, tag.tag, tag.commit });
    self.store.linkLatest(loc.shallowCloneWithVersion(tag.tag)) catch |err| {
        repo_log.err("Failed to link latest for: {s}@{s}: {any}", .{
            loc.repository,
            loc.version,
            err,
        });
        return;
    };
    // Queue a job for the detected latest version
    const cloned = loc.clone(self.allocator, tag.tag) catch |err| {
        repo_log.err("Failed to clone location: {any}", .{err});
        return;
    };
    var job = Job.init(cloned, .SyncRepository);
    self.worker_pool.addJob(
        job,
        Self.runJob,
        .{ self, job },
    ) catch |err| {
        job.deinit();
        repo_log.err("Failed to queue job for: {s}@{s}: {any}", .{
            loc.repository,
            tag.tag,
            err,
        });
    };
}

const BuildFile = "build.zig";
const MaxBuildFileSize = 1 * 1024 * 1024; // 1MB

fn syncRepositoryDocs(self: *Self, location: RemoteSource) void {
    // Get a temporary directory and clone the repository
    var tmp = TempDir.create(self.allocator, .{ .retain = false }) catch |err| {
        repo_log.err("Failed to create temporary directory: {any}", .{err});
        return;
    };
    defer tmp.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const parent = tmp.parent_dir.realpath(".", buf[0..]) catch |err| {
        repo_log.err("Failed to resolve temporary directory: {any}", .{err});
        return;
    };
    const tmppath = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ parent, tmp.basename }) catch {
        repo_log.err("Failed to allocate temporary path: {any}", .{StorageError.OutOfMemory});
        return;
    };
    defer self.allocator.free(tmppath);
    repo_log.debug("Working in temporary directory: {s}", .{tmppath});

    var repo = self.git.initRepository(self.allocator, tmppath) catch |err| {
        repo_log.err("Failed to initialize repository: {any}", .{err});
        return;
    };
    defer repo.deinit();
    repo_log.info("Cloning repository: {s}@{s}", .{ location.repository, location.version });
    repo.clone(location.repository, location.version) catch |err| {
        repo_log.err("Failed to clone repository: {s}@{s}: {any}", .{ location.repository, location.version, err });
        return;
    };

    // Check if the repository has a build.zig file
    _ = repo.dir.statFile(BuildFile) catch |err| {
        switch (err) {
            error.FileNotFound => {
                repo_log.warn("Repository {s}@{s} does not contain a build.zig file", .{ location.repository, location.version });
                return;
            },
            else => {
                repo_log.err("Failed to stat build.zig file: {any}", .{err});
                return;
            },
        }
    };

    // Build the documentation
    repo_log.info("Building documentation for {s}@{s}", .{ location.repository, location.version });
    var doc_manifest = self.builder.build(&repo) catch |err| {
        repo_log.err("Failed to build documentation for {s}@{s}: {any}", .{ location.repository, location.version, err });
        return;
    };
    defer doc_manifest.deinit();

    // Write the documentation to the storage backend
    repo_log.info("Saving documentation for {s}@{s}", .{ location.repository, location.version });
    self.store.writeManifest(location, doc_manifest) catch |err| {
        repo_log.err("Failed to write documentation for {s}@{s}: {any}", .{ location.repository, location.version, err });
    };
}
