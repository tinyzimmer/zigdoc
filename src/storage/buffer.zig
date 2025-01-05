const std = @import("std");

const Allocator = std.mem.Allocator;
const File = std.fs.File;
const FixedBufferStream = std.io.FixedBufferStream;

const Self = @This();

allocator: ?Allocator = null,
content_type: []const u8 = "text/html",
src: union(enum) {
    file: File,
    buffer: FixedBufferStream([]const u8),
},

pub fn initBuffer(allocator: Allocator, buf: []const u8) Self {
    return .{
        .allocator = allocator,
        .src = .{ .buffer = std.io.fixedBufferStream(buf) },
    };
}

pub fn initFile(file: File, content_type: []const u8) Self {
    return .{ .content_type = content_type, .src = .{ .file = file } };
}

const Reader = std.io.Reader(
    *Self,
    anyerror,
    read,
);

pub fn reader(self: *Self) Reader {
    return .{ .context = self };
}

pub fn read(self: *Self, dest: []u8) anyerror!usize {
    switch (self.src) {
        .file => return self.src.file.read(dest),
        .buffer => return self.src.buffer.read(dest),
    }
}

pub fn deinit(self: *Self) void {
    switch (self.src) {
        .file => self.src.file.close(),
        .buffer => {
            if (self.allocator != null) {
                self.allocator.?.free(self.src.buffer.buffer);
            }
        },
    }
}
