const std = @import("std");

const DateTime = @import("zdt").Datetime;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = "(" ++ switch (scope) {
        .main,
        .server,
        .service,
        .repository,
        .worker_pool,
        .storage,
        .local_dir,
        .git,
        .docs,
        std.log.default_log_scope,
        => @tagName(scope),
        else => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err))
            @tagName(scope)
        else
            return,
    } ++ "): ";

    const prefix = comptime blk: {
        const lower = level.asText();
        var upper: [lower.len]u8 = undefined;
        _ = std.ascii.upperString(&upper, lower);
        break :blk "[" ++ upper ++ "] " ++ scope_prefix;
    };

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    const stderr = std.io.getStdErr().writer();

    nosuspend {
        DateTime.nowUTC().format("", .{}, stderr) catch return;
        stderr.print(" " ++ prefix ++ format ++ "\n", args) catch return;
    }
}
