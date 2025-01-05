//! Main entrypoint for the zigdocs server.

const std = @import("std");
const builtin = @import("builtin");

const httpz = @import("httpz");

const logging = @import("logging.zig");
pub const std_options = std.Options{
    .logFn = logging.logFn,
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
    },
};

const App = @import("app.zig");
const Repository = @import("repository.zig");
const Service = @import("service.zig");
const Storage = @import("storage.zig");

const main_log = std.log.scoped(.main);

var server_instance: ?*httpz.Server(*App) = null;
var repository_instance: ?*Repository = null;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var store = try Storage.initLocalDir(allocator, "data");
    defer store.deinit();
    var repo = Repository.init(allocator, &store);
    defer repo.deinit();
    var svc = Service.init(&repo);

    var app = App{ .allocator = allocator, .service = &svc };

    var server = try httpz.Server(*App).init(
        allocator,
        .{
            .port = 8080,
            .address = "::",
            .workers = .{
                .count = 8,
            },
        },
        &app,
    );
    defer server.deinit();

    var router = server.router(.{
        // .middlewares = &.{},
    });

    router.get("/", App.index, .{});
    router.get("/subscribe/*", App.subscribeDocs, .{});
    router.get("/*", App.getDocs, .{});

    // call the shutdown method when the server receives a SIGINT or SIGTERM
    std.posix.sigaction(std.posix.SIG.INT, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);
    std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = shutdown },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    repository_instance = &repo;
    server_instance = &server;

    main_log.info("Starting server on port 8080", .{});
    try server.listen();
}

fn shutdown(_: c_int) callconv(.C) void {
    main_log.info("Received signal, shutting down", .{});
    if (repository_instance) |repo| {
        repository_instance = null;
        main_log.info("Shutting down repository and worker pool", .{});
        repo.deinit();
    }
    if (server_instance) |server| {
        server_instance = null;
        main_log.info("Shutting down web server", .{});
        server.stop();
    }
}
