const std = @import("std");
const httpz = @import("httpz");
const mustache = @import("mustache");

const Allocator = std.mem.Allocator;
const Timer = std.time.Timer;

const RemoteSource = @import("remotesource.zig");
const Service = @import("service.zig");
const SourceError = RemoteSource.SourceError;
const ServiceError = Service.ServiceError;

const Self = @This();

const server_log = std.log.scoped(.server);

pub const RequestContext = struct {
    allocator: Allocator,
    arena: Allocator,
    service: *Service,
};

const index_html_template = @embedFile("public/index.html");
const queued_html_template = @embedFile("public/queued.html");
const modules_html_template = @embedFile("public/modules.html");
const logo_svg = @embedFile("public/logo.svg");
const css_data = @embedFile("public/style.css");

allocator: Allocator,
service: *Service,

pub fn dispatch(self: *Self, action: httpz.Action(*RequestContext), req: *httpz.Request, res: *httpz.Response) !void {
    var timer = try Timer.start();

    defer {
        server_log.info("{} {s} {d} - {d}", .{
            req.method, req.url.path, std.fmt.fmtDuration(timer.lap()), res.status,
        });
    }

    // We store both the response arena and the global allocator in the context.
    // This is because server-side events need to allocate memory after the response
    // arena has been freed.
    var ctx = RequestContext{
        .allocator = self.allocator,
        .arena = res.arena,
        .service = self.service,
    };

    action(&ctx, req, res) catch |err| {
        // Handle errors explicitly so status gets set correctly
        self.uncaughtError(req, res, err);
    };
}

pub fn uncaughtError(_: *Self, _: *httpz.Request, res: *httpz.Response, err: anyerror) void {
    // Assume a 500 error by default
    res.status = 500;
    var msg: []const u8 = undefined;
    switch (err) {
        SourceError.UnsupportedHost => {
            msg = "The host of the remote repository is not supported";
        },
        SourceError.InvalidPath => {
            msg = "The repository path provided is invalid";
        },
        ServiceError.ModuleNotFound => {
            msg = "The requested module was not found in the requested repository";
        },
        else => msg = "Internal Server Error",
    }
    jsonify(res, .{ .@"error" = err, .message = msg }) catch |jsonifyErr| {
        server_log.err("Failed to jsonify {s}: {s}", .{ @errorName(err), @errorName(jsonifyErr) });
        res.body = "Internal Server Error";
    };
}

pub fn index(ctx: *RequestContext, req: *httpz.Request, res: *httpz.Response) !void {
    res.status = 200;
    res.header("Content-Type", "text/html");
    try mustache.renderText(ctx.arena, index_html_template, .{
        .css = css_data,
        .logo = logo_svg,
        .url = req.url.raw,
    }, res.writer());
}

pub fn getDocs(ctx: *RequestContext, req: *httpz.Request, res: *httpz.Response) !void {
    const location = trimPath(req.url.path);
    var source = try RemoteSource.parse(ctx.arena, location);
    defer source.deinit();

    if (source.module.len == 0) {
        // Caller is requesting the modules list
        const modules = ctx.service.getModulesList(ctx.arena, source) catch |err| {
            switch (err) {
                ServiceError.QueuedManifestSync => {
                    res.status = 200;
                    res.header("Content-Type", "text/html");
                    try mustache.renderText(ctx.arena, queued_html_template, .{
                        .css = css_data,
                        .logo = logo_svg,
                        .repo = source.repository,
                        .basename = basename(source.repository),
                        .version = source.version,
                    }, res.writer());
                    return;
                },
                else => return err,
            }
        };
        defer {
            for (modules) |module| {
                defer ctx.arena.free(module);
            }
            ctx.arena.free(modules);
        }
        res.status = 200;
        res.header("Content-Type", "text/html");
        try mustache.renderText(ctx.arena, modules_html_template, .{
            .css = css_data,
            .logo = logo_svg,
            .repo = source.repository,
            .basename = basename(source.repository),
            .version = source.version,
            .modules = modules,
        }, res.writer());
        return;
    }

    var doc_file = ctx.service.getDocsResource(ctx.arena, source) catch |err| {
        switch (err) {
            ServiceError.QueuedManifestSync => {
                res.status = 200;
                res.header("Content-Type", "text/html");
                try mustache.renderText(ctx.arena, queued_html_template, .{
                    .css = css_data,
                    .logo = logo_svg,
                    .repo = source.repository,
                    .basename = basename(source.repository),
                    .version = source.version,
                }, res.writer());
                return;
            },
            else => return err,
        }
    };
    defer doc_file.deinit();

    res.status = 200;
    res.header("Content-Type", doc_file.content_type);
    var writer = res.writer();
    var reader = doc_file.reader();
    var buf: [4096]u8 = undefined;
    var n: usize = 1;
    while (n > 0) {
        n = try reader.read(&buf);
        _ = try writer.write(buf[0..n]);
    }
}

const SubscribeContext = struct {
    arena: Allocator,
    service: *Service,
    location: []const u8,

    fn handle(self: SubscribeContext, stream: std.net.Stream) void {
        defer stream.close();
        var source = RemoteSource.parse(self.arena, self.location) catch {
            stream.writeAll("invalid repository path\n") catch return;
            return;
        };
        defer source.deinit();
        var timer = Timer.start() catch return;
        while (timer.read() < 20 * std.time.ns_per_s) {
            const modules = self.service.getModulesList(self.arena, source) catch {
                std.Thread.sleep(2 * std.time.ns_per_s);
                continue;
            };
            self.arena.free(modules);
            for (modules) |module| {
                self.arena.free(module);
            }
            stream.writeAll("event: ready\ndata:{}\n\n") catch return;
            return;
        }
    }
};

pub fn subscribeDocs(ctx: *RequestContext, req: *httpz.Request, res: *httpz.Response) !void {
    try res.startEventStream(SubscribeContext{
        .arena = ctx.allocator,
        .service = ctx.service,
        .location = trimPathPrefix(req.url.path, "subscribe/"),
    }, SubscribeContext.handle);
}

fn trimPath(path: []const u8) []const u8 {
    return std.mem.trim(u8, path, "/");
}

fn trimPathPrefix(path: []const u8, prefix: []const u8) []const u8 {
    const trimLeft = std.mem.trimLeft(u8, path, prefix);
    return trimPath(trimLeft);
}

fn basename(path: []const u8) []const u8 {
    const last_slash = std.mem.lastIndexOf(u8, path, "/");
    if (last_slash == null) return path;
    return path[last_slash.? + 1 ..];
}

fn jsonify(res: *httpz.Response, value: anytype) !void {
    try res.json(value, std.json.StringifyOptions{
        .whitespace = .indent_2,
    });
    try std.fmt.format(res.writer(), "\n", .{});
    return;
}
