comptime {
    _ = @import("git/errors.zig");
    _ = @import("git/repository.zig");
    _ = @import("git/tag.zig");

    _ = @import("storage/buffer.zig");
    _ = @import("storage/errors.zig");
    _ = @import("storage/localdir.zig");

    _ = @import("app.zig");
    _ = @import("docs.zig");
    _ = @import("logging.zig");
    _ = @import("main.zig");
    _ = @import("remotesource.zig");
    _ = @import("repository.zig");
    _ = @import("service.zig");
    _ = @import("storage.zig");
    _ = @import("workerpool.zig");
}
