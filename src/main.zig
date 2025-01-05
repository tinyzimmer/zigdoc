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
const Docs = @import("docs.zig");
const Git = @import("git/git.zig");
const Repository = @import("repository.zig");
const Service = @import("service.zig");
const Storage = @import("storage.zig");

const main_log = std.log.scoped(.main);

var server_instance: ?*httpz.Server(*App) = null;
var repository_instance: ?*Repository = null;

var allocator: std.mem.Allocator = undefined;

var config = struct {
    global_config: struct {
        git_executable: []const u8 = "git",
        zig_executable: []const u8 = "zig",
        zig_cache_dir: []const u8 = "",
    } = .{},
    serve_config: struct {
        host: []const u8 = "::",
        port: u16 = 8080,
        http_workers: u16 = 4,
        data_dir: []const u8 = "data",
    } = .{},
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
                    .long_name = "git-executable",
                    .help = "path to the git executable (defaults to 'git')",
                    .value_ref = r.mkRef(&config.global_config.git_executable),
                },
                .{
                    .long_name = "zig-executable",
                    .help = "path to the zig executable (defaults to 'zig')",
                    .value_ref = r.mkRef(&config.global_config.zig_executable),
                },
                .{
                    .long_name = "zig-cache-dir",
                    .help = "directory to store zig cache, defaults to the global zig cache directory",
                    .value_ref = r.mkRef(&config.global_config.zig_cache_dir),
                },
            },
            .target = cli.CommandTarget{
                .subcommands = &.{
                    .{
                        .name = "serve",
                        .options = &.{
                            .{
                                .long_name = "host",
                                .help = "host to listen on",
                                .value_ref = r.mkRef(&config.serve_config.host),
                            },
                            .{
                                .long_name = "port",
                                .help = "port to bind to",
                                .value_ref = r.mkRef(&config.serve_config.port),
                            },
                            .{
                                .long_name = "http-workers",
                                .help = "number of http worker threads",
                                .value_ref = r.mkRef(&config.serve_config.http_workers),
                            },
                            .{
                                .long_name = "data-dir",
                                .help = "directory to store data",
                                .value_ref = r.mkRef(&config.serve_config.data_dir),
                            },
                        },
                        .target = cli.CommandTarget{
                            .action = cli.CommandAction{
                                .exec = runServer,
                            },
                        },
                    },
                },
            },
        },
    };
    return r.run(&app);
}

fn runServer() !void {
    var store = try Storage.initLocalDir(allocator, config.serve_config.data_dir);
    defer store.deinit();

    const doc_builder = Docs.init(config.global_config.zig_executable, config.global_config.zig_cache_dir);
    const git = Git.init(config.global_config.git_executable);
    var repo = Repository.init(allocator, &store, doc_builder, git);
    defer repo.deinit();

    var svc = Service.init(&repo);

    var app = App{ .allocator = allocator, .service = &svc };

    var server = try httpz.Server(*App).init(
        allocator,
        .{
            .port = config.serve_config.port,
            .address = config.serve_config.host,
            .workers = .{
                .count = config.serve_config.http_workers,
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
    if (builtin.os.tag != .windows) {
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
    }
    repository_instance = &repo;
    server_instance = &server;

    main_log.info("Starting server on http://{s}:{d}", .{ config.serve_config.host, config.serve_config.port });
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
