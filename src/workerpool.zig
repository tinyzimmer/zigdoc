const std = @import("std");

const RemoteSource = @import("remotesource.zig");

const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const Thread = std.Thread;
const Mutex = Thread.Mutex;

const worker_log = std.log.scoped(.worker_pool);

pub const WorkerError = error{
    JobExists,
    JobStartFailed,
    PoolStopped,
    OutOfMemory,
};

pub const JobType = enum {
    SyncLatest,
    SyncRepository,
};

/// A job to be run by the worker pool. This structure is mainly used for
/// acting as the "key" to the worker pool hashmap.
pub const Job = struct {
    location: RemoteSource,
    job_type: JobType,

    pub fn init(location: RemoteSource, job_type: JobType) Job {
        return .{
            .location = location,
            .job_type = job_type,
        };
    }

    pub fn hashKey(self: Job, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}_{s}@{s}", .{
            @tagName(self.job_type),
            self.location.repository,
            self.location.version,
        });
    }

    pub fn deinit(self: *Job) void {
        self.location.deinit();
    }
};

const Self = @This();

threads: StringHashMap(Thread) = undefined,
mutex: Mutex = Mutex{},
shutdown: bool = false,

pub fn init(allocator: Allocator) Self {
    return .{
        .threads = StringHashMap(Thread).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.mutex.lock();
    if (self.shutdown) {
        self.mutex.unlock();
        return;
    }
    defer self.threads.deinit();
    self.shutdown = true;
    // We need to unlock the mutex before joining the threads
    // so that they can remove themselves from the hashmap
    self.mutex.unlock();
    var it = self.threads.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const thread = kv.value_ptr.*;
        worker_log.info("Waiting for {s} job to complete", .{key});
        thread.join();
        self.threads.allocator.free(key);
    }
}

/// Adds a job to the worker pool.
pub fn addJob(self: *Self, job: Job, comptime function: anytype, args: anytype) WorkerError!void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.shutdown) {
        return WorkerError.PoolStopped;
    }

    const key = job.hashKey(self.threads.allocator) catch {
        return WorkerError.OutOfMemory;
    };
    errdefer self.threads.allocator.free(key);

    if (self.threads.contains(key)) {
        return WorkerError.JobExists;
    }

    worker_log.debug("Starting {s} job for: {s}@{s}", .{
        @tagName(job.job_type),
        job.location.repository,
        job.location.version,
    });
    const thread = Thread.spawn(.{}, function, args) catch {
        return WorkerError.JobStartFailed;
    };
    errdefer thread.detach();

    self.threads.put(key, thread) catch {
        return WorkerError.OutOfMemory;
    };
}

/// Can be called by a job to indicate that it has completed.
pub fn completeJob(self: *Self, job: Job) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (self.shutdown) {
        return;
    }
    worker_log.debug("Completed {s} job for: {s}@{s}", .{
        @tagName(job.job_type),
        job.location.repository,
        job.location.version,
    });
    const key = job.hashKey(self.threads.allocator) catch |err| {
        worker_log.err("Failed to hash job key: {any}", .{err});
        return;
    };
    defer self.threads.allocator.free(key);

    const kv = self.threads.getEntry(key) orelse return;
    const keyval = kv.key_ptr.*;
    defer self.threads.allocator.free(keyval);
    self.threads.removeByPtr(kv.key_ptr);
}

fn testJob(self: *Self, job: Job, some_int: *i64) void {
    some_int.* = 42;
    self.completeJob(job);
}

fn testSleepingJob(self: *Self, job: Job) void {
    Thread.sleep(std.time.ns_per_s);
    self.completeJob(job);
}

test "WorkerPool: jobs" {
    const allocator = std.testing.allocator;
    var pool = Self.init(allocator);
    var some_int: i64 = 0;

    const job = Job.init(
        .{
            .repository = "test",
            .version = "latest",
            .module = "test",
            .file = "test",
            .allocator = null,
        },
        .SyncLatest,
    );
    try pool.addJob(job, Self.testJob, .{ &pool, job, &some_int });

    // Deinit the pool, it should wait for the job to complete
    pool.deinit();
    try std.testing.expectEqual(some_int, 42);

    // Try to create duplicate jobs
    pool = Self.init(allocator);
    try pool.addJob(job, Self.testSleepingJob, .{ &pool, job });
    try std.testing.expectError(
        WorkerError.JobExists,
        pool.addJob(job, Self.testSleepingJob, .{ &pool, job }),
    );
    pool.deinit();
}
