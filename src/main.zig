const std = @import("std");

const xev = @import("xev");

const log = std.log;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var thread_pool: ?xev.ThreadPool = switch (xev.backend) {
        .epoll, .kqueue => xev.ThreadPool.init(.{ .max_threads = 2 }),
        else => null,
    };
    defer if (thread_pool) |*tp| tp.deinit();

    var loop = try xev.Loop.init(.{ .thread_pool = if (thread_pool) |*tp| tp else null });
    defer loop.deinit();

    const accept_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    const accept_socket = try xev.TCP.init(accept_address);
    defer std.os.close(accept_socket.fd);
    try accept_socket.bind(accept_address);
    try accept_socket.listen(32);
    var accept_completion: xev.Completion = undefined;
    accept_socket.accept(&loop, &accept_completion, void, null, onAccept);

    try loop.run(.until_done);
}

fn onAccept(
    _: ?*void,
    l: *xev.Loop,
    c: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    _ = l; // autofix
    _ = c; // autofix
    const socket = r catch |err| {
        log.err("accept: {any}", .{err});
        return .disarm;
    };
    log.debug("accepted", .{});
    std.os.close(socket.fd);
    return .rearm;
}
