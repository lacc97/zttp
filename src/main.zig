const std = @import("std");
const builtin = @import("builtin");

const xev = @import("xev");

const Buffer = @import("./buffer.zig").Buffer;
const BufferPool = @import("./buffer.zig").BufferPool;

const log = std.log;

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

    var server = try Server.init(gpa);
    defer server.deinit();

    const accept_address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8080);
    const accept_socket = try xev.TCP.init(accept_address);
    defer std.os.close(accept_socket.fd);
    try accept_socket.bind(accept_address);
    try accept_socket.listen(32);
    var accept_completion: xev.Completion = undefined;
    accept_socket.accept(&loop, &accept_completion, Server, &server, onAccept);

    log.info("listening on {}", .{accept_address});
    try loop.run(.until_done);
}

const Server = struct {
    gpa: std.mem.Allocator,

    buffer_pool: BufferPool,
    connection_pool: std.heap.MemoryPool(Connection),

    const Connection = struct {
        gpa: std.mem.Allocator,
        server: *Server,
        socket: xev.TCP,

        read_completion: xev.Completion = undefined,
        write_completion: xev.Completion = undefined,
        close_completion: xev.Completion = undefined,

        fn create(server: *Server, socket: xev.TCP) error{OutOfMemory}!*Connection {
            const conn = try server.connection_pool.create();
            errdefer server.connection_pool.destroy(conn);

            conn.* = .{
                .gpa = server.gpa,
                .server = server,
                .socket = socket,
            };

            return conn;
        }

        fn destroy(conn: *Connection) void {
            conn.server.connection_pool.destroy(conn);
        }

        fn allocBuffer(conn: *Connection, min_size: usize) error{OutOfMemory}!Buffer {
            return conn.server.buffer_pool.alloc(min_size);
        }
        fn freeBuffer(conn: *Connection, buf: Buffer) void {
            return conn.server.buffer_pool.free(buf);
        }
    };

    fn init(gpa: std.mem.Allocator) !Server {
        return .{
            .gpa = gpa,
            .buffer_pool = try BufferPool.init(gpa, .{ .max_size_bits = 20 }),
            .connection_pool = std.heap.MemoryPool(Connection).init(gpa),
        };
    }

    fn deinit(server: *Server) void {
        server.connection_pool.deinit();
        server.buffer_pool.deinit();
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
    const conn = Server.Connection.create(server, socket) catch {
        log.err("accept: out of memory", .{});
        std.os.close(socket.fd);
        return .rearm;
    };
    const buf = conn.allocBuffer(2048) catch {
        log.err("accept: out of memory", .{});
        conn.destroy();
        std.os.close(socket.fd);
        return .rearm;
    };
    conn.socket.read(l, &conn.read_completion, buf.intoReadBuffer(), Server.Connection, conn, connRead);
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
    const buf = Buffer.fromReadBuffer(b);

    const read_size = r catch |err| {
        log.err("read: {any}", .{err});
        conn.freeBuffer(buf);
        conn.socket.close(l, &conn.close_completion, Server.Connection, conn, connClose);
        return .disarm;
    };

    log.debug("recv: {s}", .{b.slice[0..read_size]});

    const response = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n";
    @memcpy(buf.slice()[0..response.len], response);
    conn.socket.write(l, &conn.write_completion, buf.intoWriteBuffer(), Server.Connection, conn, connWrite);

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
    const buf = Buffer.fromWriteBuffer(b);
    defer conn.freeBuffer(buf);

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
    defer conn.destroy();

    r catch |err| log.err("close: {any}", .{err});

    return .disarm;
}

test {
    _ = @import("./buffer.zig");
}
