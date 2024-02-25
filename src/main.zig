const std = @import("std");

const xev = @import("xev");

const log = std.log;

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

    var server = Server{ .gpa = gpa };
    defer server.deinit();

    const accept_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    const accept_socket = try xev.TCP.init(accept_address);
    defer std.os.close(accept_socket.fd);
    try accept_socket.bind(accept_address);
    try accept_socket.listen(32);
    var accept_completion: xev.Completion = undefined;
    accept_socket.accept(&loop, &accept_completion, Server, &server, onAccept);

    try loop.run(.until_done);
}

const Server = struct {
    gpa: std.mem.Allocator,

    const Connection = struct {
        gpa: std.mem.Allocator,
        server: *Server,
        socket: xev.TCP,

        read_completion: xev.Completion = undefined,
        write_completion: xev.Completion = undefined,
        close_completion: xev.Completion = undefined,
    };

    fn deinit(server: *Server) void {
        _ = server; // autofix
    }
};

fn onAccept(
    s: ?*Server,
    l: *xev.Loop,
    c: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const server = s.?;
    _ = c; // autofix
    const socket = r catch |err| {
        log.err("accept: {any}", .{err});
        return .disarm;
    };
    const conn = server.gpa.create(Server.Connection) catch {
        log.err("accept: out of memory", .{});
        std.os.close(socket.fd);
        return .rearm;
    };
    conn.* = .{ .gpa = server.gpa, .server = server, .socket = socket };
    const read_buffer = conn.gpa.alloc(u8, 1024) catch {
        log.err("accept: out of memory", .{});
        server.gpa.destroy(conn);
        std.os.close(socket.fd);
        return .rearm;
    };
    conn.socket.read(l, &conn.read_completion, .{ .slice = read_buffer }, Server.Connection, conn, connRead);
    log.debug("accepted", .{});
    return .rearm;
}

fn connRead(
    ud: ?*Server.Connection,
    l: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    b: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = c; // autofix
    _ = s; // autofix
    const conn = ud.?;
    defer conn.gpa.free(b.slice);

    const read_size = r catch |err| {
        log.err("read: {any}", .{err});
        conn.socket.close(l, &conn.close_completion, Server.Connection, conn, connClose);
        return .disarm;
    };

    log.debug("recv: {s}", .{b.slice[0..read_size]});

    const buf =
        conn.gpa.alloc(u8, 1024) catch {
        log.err("read: out of memory for response", .{});
        return .disarm;
    };
    const response = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n";
    @memcpy(buf[0..response.len], response);
    conn.socket.write(l, &conn.write_completion, .{ .slice = buf }, Server.Connection, conn, connWrite);

    return .disarm;
}

fn connWrite(
    ud: ?*Server.Connection,
    l: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    b: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    _ = c; // autofix
    _ = s; // autofix
    const conn = ud.?;
    defer conn.gpa.free(b.slice);

    // TODO: handle partial writes?
    const write_size = r catch |err| {
        log.err("write: {any}", .{err});
        conn.socket.close(l, &conn.close_completion, Server.Connection, conn, connClose);
        return .disarm;
    };
    _ = write_size; // autofix

    log.debug("sent", .{});

    conn.socket.close(l, &conn.close_completion, Server.Connection, conn, connClose);

    return .disarm;
}

fn connClose(
    ud: ?*Server.Connection,
    l: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = l; // autofix
    _ = c; // autofix
    _ = s; // autofix

    const conn = ud.?;
    defer conn.server.gpa.destroy(conn);

    r catch |err| log.err("close: {any}", .{err});

    return .disarm;
}
