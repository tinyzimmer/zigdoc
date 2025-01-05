const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const Thread = std.Thread;

const RemoteSource = @import("remotesource.zig");

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
mutex: Thread.RwLock = undefined,
shutdown: bool = false,

pub fn init(allocator: Allocator) Self {
    return .{
        .threads = StringHashMap(Thread).init(allocator),
        .mutex = Thread.RwLock{},
    };
}

pub fn deinit(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.shutdown) {
        return;
    }
    defer self.threads.deinit();
    self.shutdown = true;
    var it = self.threads.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const thread = kv.value_ptr.*;
        worker_log.info("Waiting for {s} job to complete", .{key});
        thread.join();
        self.threads.allocator.free(key);
    }
}

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
    const thread = Thread.spawn(.{ .allocator = self.threads.allocator }, function, args) catch {
        return WorkerError.JobStartFailed;
    };
    errdefer thread.detach();

    self.threads.put(key, thread) catch {
        return WorkerError.OutOfMemory;
    };
}

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
    const key = job.hashKey(self.threads.allocator) catch {
        worker_log.err("Failed to hash job key", .{});
        return;
    };
    defer self.threads.allocator.free(key);

    const kv = self.threads.getEntry(key) orelse return;
    const keyval = kv.key_ptr.*;
    defer self.threads.allocator.free(keyval);
    self.threads.removeByPtr(kv.key_ptr);
}
