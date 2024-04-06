const std = @import("std");
const assert = std.debug.assert;

const zttp = @This();

const Request = @import("Request.zig");

const Http1StateMachine = @import("http1.zig").StateMachine;

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

            srv.connection_list.append(node);
            errdefer srv.connection_list.remove(node);

            const conn = &node.data;
            conn.init(loop, srv, sock);
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

            state_machine: Http1 = Http1.init(),
            buffer: std.BoundedArray(u8, 8192) = .{},

            pub fn init(conn: *Connection, loop: *xev.Loop, srv: *ZttpServer, sock: xev.TCP) void {
                conn.* = .{
                    .srv = srv,
                    .sock = sock,
                };

                conn.readAppend(loop) catch unreachable; // not possible because we just initialised this object
            }

            fn readAppend(conn: *Connection, loop: *xev.Loop) error{OutOfSpace}!void {
                if (conn.buffer.unusedCapacitySlice().len == 0) return error.OutOfSpace;

                conn.sock.read(loop, &conn.comp, .{ .slice = conn.buffer.unusedCapacitySlice() }, Connection, conn, onRead);
            }

            fn close(conn: *Connection, loop: *xev.Loop) void {
                conn.sock.close(loop, &conn.comp, Connection, conn, onClose);
            }

            fn onRead(
                arg_conn: ?*Connection,
                loop: *xev.Loop,
                _: *xev.Completion,
                _: xev.TCP,
                _: xev.ReadBuffer,
                result: xev.ReadError!usize,
            ) xev.CallbackAction {
                const conn = arg_conn.?;

                const len = result catch |err| {
                    log.err("read: {any}", .{err});
                    conn.close(loop);
                    return .disarm;
                };
                conn.buffer.resize(conn.buffer.len + len) catch unreachable;

                const processed = conn.state_machine.process(conn, conn.buffer.slice()) catch |err| switch (err) {
                    else => @panic("TODO: error handling"),
                };
                assert(processed == conn.buffer.len);
                conn.buffer.resize(0) catch unreachable;

                const response = "HTTP/1.1 204 No Content\r\n\r\n";
                conn.sock.write(loop, &conn.comp, .{ .slice = response }, Connection, conn, onWrite);

                return .disarm;
            }

            fn onClose(
                arg_conn: ?*Connection,
                _: *xev.Loop,
                _: *xev.Completion,
                _: xev.TCP,
                r: xev.CloseError!void,
            ) xev.CallbackAction {
                const conn = arg_conn.?;
                defer conn.srv.destroyConn(conn);
                r catch |err| log.err("close: {any}", .{err});
                return .disarm;
            }

            fn onWrite(
                arg_conn: ?*Connection,
                loop: *xev.Loop,
                _: *xev.Completion,
                _: xev.TCP,
                _: xev.WriteBuffer,
                r: xev.WriteError!usize,
            ) xev.CallbackAction {
                const conn = arg_conn.?;
                _ = r catch |err| {
                    log.err("write: {any}", .{err});
                    conn.close(loop);
                    return .disarm;
                };
                // TODO: this
                conn.readAppend(loop) catch unreachable;
                return .disarm;
            }

            const Http1 = Http1StateMachine(*Connection, Connection.onRequest, Connection.onData);

            fn onRequest(conn: *Connection, req: Request) !void {
                _ = conn;
                _ = req;
                // var buffer = std.io.bufferedWriter(std.io.getStdErr().writer());
                // defer buffer.flush() catch {};
                // req.dump(buffer.writer()) catch {};
            }

            fn onData(conn: *Connection, data: error{Closed}![]u8) !void {
                _ = conn;
                _ = data catch {};
            }
        };
        const ConnectionNode = std.DoublyLinkedList(Connection).Node;
    };
}

test {
    _ = @import("http1.zig");
}
