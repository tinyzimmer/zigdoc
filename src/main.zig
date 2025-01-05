//! Main entrypoint for the zigdocs server.

const std = @import("std");
const builtin = @import("builtin");

const cli = @import("zig-cli");
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

var allocator: std.mem.Allocator = undefined;

var config = struct {
    host: []const u8 = "::",
    port: u16 = 8080,
    workers: u16 = 4,
    data_dir: []const u8 = "data",
}{};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();

    var r = try cli.AppRunner.init(allocator);

    // Create an App with a command named "short" that takes host and port options.
    const app = cli.App{
        .command = cli.Command{
            .name = "zigdoc",
            .options = &.{
                .{
                    .long_name = "host",
                    .help = "host to listen on",
                    .value_ref = r.mkRef(&config.host),
                },
                .{
                    .long_name = "port",
                    .help = "port to bind to",
                    .value_ref = r.mkRef(&config.port),
                },
                .{
                    .long_name = "workers",
                    .help = "number of worker threads",
                    .value_ref = r.mkRef(&config.workers),
                },
                .{
                    .long_name = "data-dir",
                    .help = "directory to store data",
                    .value_ref = r.mkRef(&config.data_dir),
                },
            },
            .target = cli.CommandTarget{
                .action = cli.CommandAction{
                    .exec = run_server,
                },
            },
        },
    };
    return r.run(&app);
}

pub fn run_server() !void {
    var store = try Storage.initLocalDir(allocator, config.data_dir);
    defer store.deinit();
    var repo = Repository.init(allocator, &store);
    defer repo.deinit();
    var svc = Service.init(&repo);

    var app = App{ .allocator = allocator, .service = &svc };

    var server = try httpz.Server(*App).init(
        allocator,
        .{
            .port = config.port,
            .address = config.host,
            .workers = .{
                .count = config.workers,
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

    main_log.info("Starting server on http://{s}:{d}", .{ config.host, config.port });
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
