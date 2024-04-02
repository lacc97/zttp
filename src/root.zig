const std = @import("std");
const assert = std.debug.assert;

const zttp = @This();

pub const Config = struct {
    xev: type,
    log: ?type = null,
};

pub fn Server(comptime cfg: Config) type {
    return struct {
        const ZttpServer = @This();

        gpa: std.mem.Allocator,

        listener: ?Listener = null,

        connection_list: std.DoublyLinkedList(Connection) = .{},
        connection_pool: std.heap.MemoryPool(ConnectionNode),

        const xev = cfg.xev;

        const log = cfg.log orelse std.log.scoped(.zttp);

        pub fn init(gpa: std.mem.Allocator) ZttpServer {
            return .{
                .gpa = gpa,
                .connection_pool = std.heap.MemoryPool(ConnectionNode).init(gpa),
            };
        }

        pub fn deinit(srv: *ZttpServer) void {
            srv.connection_pool.deinit();
        }

        pub fn start(srv: *ZttpServer, loop: *xev.Loop, addr: std.net.Address, opts: StartOpts) !void {
            assert(srv.listener == null);
            srv.listener = @as(Listener, undefined);
            const listener = &srv.listener.?;
            errdefer srv.listener = null;

            const sock = try xev.TCP.init(addr);
            errdefer std.posix.close(sock.fd);
            try sock.bind(addr);
            try sock.listen(opts.backlog);
            log.info("listening on {}", .{addr});

            listener.* = .{
                .addr = addr,
                .sock = sock,
                .comp = undefined,
            };
            listener.sock.accept(loop, &listener.comp, ZttpServer, srv, onAccept);
        }

        pub const StartOpts = struct {
            backlog: u31 = 8,
        };

        const Listener = struct {
            addr: std.net.Address,
            sock: xev.TCP,
            comp: xev.Completion,
        };

        fn onAccept(
            arg_srv: ?*ZttpServer,
            loop: *xev.Loop,
            comp: *xev.Completion,
            r: xev.AcceptError!xev.TCP,
        ) xev.CallbackAction {
            _ = comp; // autofix
            const srv = arg_srv.?;
            const sock = r catch |err| {
                log.err("failed to accept: {}", .{err});
                return .rearm;
            };
            srv.newConnection(loop, sock) catch return .disarm;
            return .rearm;
        }

        fn newConnection(srv: *ZttpServer, loop: *xev.Loop, sock: xev.TCP) !void {
            errdefer std.posix.close(sock.fd);

            const node: *ConnectionNode = try srv.connection_pool.create();
            errdefer srv.connection_pool.destroy(node);

            const conn = &node.data;
            conn.* = .{
                .srv = srv,
                .sock = sock,
            };

            srv.connection_list.append(node);
            errdefer srv.connection_list.remove(node);

            conn.sock.read(loop, &conn.comp, .{ .slice = &conn.buffer }, Connection, conn, connRead);
        }

        fn destroyConn(srv: *ZttpServer, conn: *Connection) void {
            const node: *ConnectionNode = @fieldParentPtr(ConnectionNode, "data", conn);

            srv.connection_list.remove(node);
            srv.connection_pool.destroy(node);
        }

        const Connection = struct {
            srv: *ZttpServer,

            sock: xev.TCP,
            comp: xev.Completion = undefined,

            buffer: [8192]u8 = undefined,
        };
        const ConnectionNode = std.DoublyLinkedList(Connection).Node;

        fn connRead(
            arg_conn: ?*Connection,
            loop: *xev.Loop,
            comp: *xev.Completion,
            _: xev.TCP,
            buffer: xev.ReadBuffer,
            result: xev.ReadError!usize,
        ) xev.CallbackAction {
            _ = buffer; // autofix
            const conn = arg_conn.?;

            const read_size = result catch |err| {
                log.err("read: {any}", .{err});
                conn.sock.close(loop, comp, Connection, conn, connClose);
                return .disarm;
            };
            _ = read_size; // autofix

            const response = "HTTP/1.1 204 No Content\r\n\r\n";
            @memcpy(conn.buffer[0..response.len], response);
            conn.sock.write(loop, comp, .{ .slice = conn.buffer[0..response.len] }, Connection, conn, connWrite);

            return .disarm;
        }

        fn connWrite(
            arg_conn: ?*Connection,
            loop: *xev.Loop,
            comp: *xev.Completion,
            _: xev.TCP,
            buffer: xev.WriteBuffer,
            r: xev.WriteError!usize,
        ) xev.CallbackAction {
            _ = buffer; // autofix
            const conn = arg_conn.?;

            // TODO: handle partial writes?
            const write_size = r catch |err| {
                log.err("write: {any}", .{err});
                conn.sock.close(loop, comp, Connection, conn, connClose);
                return .disarm;
            };
            _ = write_size; // autofix

            conn.sock.read(loop, &conn.comp, .{ .slice = &conn.buffer }, Connection, conn, connRead);

            return .disarm;
        }

        fn connClose(
            arg_conn: ?*Connection,
            loop: *xev.Loop,
            comp: *xev.Completion,
            _: xev.TCP,
            r: xev.CloseError!void,
        ) xev.CallbackAction {
            _ = loop; // autofix
            _ = comp; // autofix
            const conn = arg_conn.?;
            defer conn.srv.destroyConn(conn);

            r catch |err| log.err("close: {any}", .{err});

            return .disarm;
        }
    };
}

test {
    _ = @import("http1.zig");
}
