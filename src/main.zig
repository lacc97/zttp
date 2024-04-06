const std = @import("std");
const builtin = @import("builtin");

const xev = @import("xev");

const Buffer = @import("./buffer.zig").Buffer;
const BufferPool = @import("./buffer.zig").BufferPool;

const log = std.log;

const zttp = @import("zttp");

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
};

const use_gpa = false;

pub fn main() !void {
    var gpa_state = if (use_gpa) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer _ = if (use_gpa) gpa_state.deinit() else &gpa_state;
    const gpa = if (use_gpa) gpa_state.allocator() else std.heap.page_allocator;

    var thread_pool: ?xev.ThreadPool = switch (xev.backend) {
        .epoll, .kqueue => xev.ThreadPool.init(.{ .max_threads = 2 }),
        else => null,
    };
    defer if (thread_pool) |*tp| tp.deinit();

    var loop = try xev.Loop.init(.{ .thread_pool = if (thread_pool) |*tp| tp else null });
    defer loop.deinit();

    var server = zttp.Server(.{ .xev = xev }).init(gpa);
    defer server.deinit();

    try server.start(
        &loop,
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080),
        .{ .backlog = 8 },
    );
    try loop.run(.until_done);
}

test {
    _ = @import("./buffer.zig");
}
