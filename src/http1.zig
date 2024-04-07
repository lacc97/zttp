const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const constants = @import("constants.zig");

const Request = @import("Request.zig");

pub fn StateMachine(
    comptime Context: type,
    comptime on_request: anytype,
    comptime on_data: anytype,
) type {
    const onRequest = struct {
        fn onRequest(ctx: Context, req: Request) !void {
            // TODO: check function, handle errors
            return @call(.always_inline, on_request, .{ ctx, req });
        }
    }.onRequest;

    const onData = struct {
        fn onData(ctx: Context, data: error{Closed}![]u8) !void {
            // TODO: check function, handle errors
            return @call(.always_inline, on_data, .{ ctx, data });
        }
    }.onData;

    return union(enum) {
        headers,
        body: Chunk,
        body_chunked: ?Chunk,

        pub fn init() @This() {
            return .headers;
        }

        pub fn process(sm: *@This(), ctx: Context, data: []u8) !usize {
            return switch (sm.*) {
                .headers => blk_headers: {
                    var req_headers: [constants.http1_headers_count_max]Request.StringKeyValue.Entry = undefined;
                    var req: Request, const consumed: usize = try parseRequestLineAndHeaders(data, &req_headers);

                    const transfer_encoding = getTransferEncoding(req.headers()) catch {
                        return error.InvalidFraming;
                    };
                    const content_length = getContentLength(req.headers()) catch {
                        return error.InvalidFraming;
                    };

                    if (transfer_encoding) |te| {
                        if (content_length != null) {
                            return error.InvalidFraming;
                        }
                        if (te != .chunked) {
                            return error.UnsupportedCoding;
                        }
                        sm.* = .{ .body_chunked = null };
                    } else {
                        const length = if (content_length) |ce| ce else 0;

                        // If the length is zero, the message has no body and would be
                        // immediately followed by another request (if any).
                        if (length != 0) {
                            sm.* = .{ .body = .{ .cur = 0, .len = length } };
                        }
                    }
                    try onRequest(ctx, req);
                    break :blk_headers consumed;
                },
                .body => |*body| blk_body: {
                    const consumed = @min(@as(u64, data.len), body.len - body.cur);
                    body.cur += consumed;
                    if (body.cur == body.len) sm.* = .headers;
                    try onData(ctx, data[0..consumed]);
                    break :blk_body consumed;
                },
                .body_chunked => |*body| {
                    _ = body;
                    @panic("TODO: RFC9112 section 7.1");
                },
            };
        }
    };
}

const Chunk = struct {
    cur: u64 = 0,
    len: u64,
};

test StateMachine {
    for (test_cases_correct) |case| {
        const Header = @typeInfo(@TypeOf(case.headers)).Pointer.child;
        const Context = struct {
            case: @TypeOf(case),
            request_received: bool = false,
            data_received: u64 = 0,

            fn onRequest(ctx: *@This(), req: Request) !void {
                try testing.expectEqualStrings(ctx.case.method, req.method);
                try testing.expectEqualStrings(ctx.case.path, req.path);

                const headers = try testing.allocator.alloc(Header, req.headers.len());
                defer testing.allocator.free(headers);

                {
                    var i: usize = 0;
                    var it = req.headers.iterator();
                    while (it.next()) |hdr| : (i += 1) headers[i] = .{ .name = hdr.name, .value = hdr.value };
                    try testing.expectEqual(headers.len, i);
                }

                std.sort.pdq(Header, headers, Header.SortContext{}, Header.SortContext.lessThan);

                for (0..@max(headers.len, ctx.case.headers.len)) |i| {
                    const name_expected = if (ctx.case.headers.len > i) ctx.case.headers[i].name else "";
                    const value_expected = if (ctx.case.headers.len > i) ctx.case.headers[i].value else "";
                    const name_got = if (headers.len > i) headers[i].name else "";
                    const value_got = if (headers.len > i) headers[i].value else "";

                    try testing.expectEqualStrings(name_expected, name_got);
                    try testing.expectEqualStrings(value_expected, value_got);
                }

                ctx.request_received = true;
            }

            fn onData(ctx: *@This(), data: error{Closed}![]u8) !void {
                _ = ctx;
                _ = data catch @panic("we're closed");
                @panic("TODO: ");
            }
        };

        const SM = StateMachine(
            *Context,
            Context.onRequest,
            Context.onData,
        );

        const buf = try testing.allocator.dupe(u8, case.bytes);
        defer testing.allocator.free(buf);

        var sm = SM.init();
        var sm_context: Context = .{ .case = case };

        try testing.expectError(error.NeedMore, sm.process(&sm_context, buf[0 .. buf.len / 2]));
        try testing.expectEqual(@as(usize, buf.len), sm.process(&sm_context, buf));
        try testing.expect(sm_context.request_received);
    }
}

fn getTransferEncoding(hm: Request.StringKeyValue.ReifyConst) error{Invalid}!?TransferEncoding {
    // TODO: get transfer-encoding stack and verify that the last coding is chunked (RFC9112 section 6.1)
    const h = hm.get("transfer-encoding") orelse return null;
    return if (std.mem.eql(u8, std.mem.trim(u8, h.v, " \t"), "chunked"))
        .chunked
    else
        return error.Invalid;
}

const TransferEncoding = enum {
    chunked,
    // TODO: gzip?
};

fn getContentLength(hm: Request.StringKeyValue.ReifyConst) error{Invalid}!?u64 {
    const h = hm.get("content-length") orelse return null;
    return std.fmt.parseUnsigned(u64, h.v, 10) catch error.Invalid;
}

fn parseRequestLineAndHeaders(data: []u8, headers_storage: []Request.StringKeyValue.Entry) !struct { Request, usize } {
    assert(data.len > 0);

    var p: RequestParser = .{
        .data = data,
        .curr = 0,
    };

    const method = try p.parseMethod();
    const path = try p.parsePath();
    const version = try p.parseVersion();
    if (!std.mem.eql(u8, p.advance(2), "\r\n")) return error.InvalidToken;

    var headers = std.ArrayListUnmanaged(Request.StringKeyValue.Entry).initBuffer(headers_storage);
    while (try p.parseField()) |hdr| {
        if (headers.items.len == headers.capacity) return error.OutOfSpace;
        headers.appendAssumeCapacity(hdr);
    }

    return .{ .{
        .data = p.data[0..p.curr],

        ._method = method,
        ._path = path,
        ._version = version,
        ._headers = .{ .buf = headers.items },
    }, p.curr };
}

const RequestParser = struct {
    data: []u8,
    curr: u32,

    fn parseMethod(p: *RequestParser) !Request.ByteSlice {
        const sp_off: u32 = for (p.data[p.curr..], 0..) |ch, i| {
            if (!isMethodChar(ch)) {
                if (ch != ' ') return error.InvalidToken;
                break @intCast(i);
            }
        } else return error.NeedMore;
        return p.advanceByteSlice(sp_off + 1).sub(0, sp_off);
    }

    fn parsePath(p: *RequestParser) !Request.ByteSlice {
        const sp_off: u32 = for (p.data[p.curr..], 0..) |ch, i| {
            if (!isPathChar(ch)) {
                if (ch != ' ') return error.InvalidToken;
                break @intCast(i);
            }
        } else return error.NeedMore;
        return p.advanceByteSlice(sp_off + 1).sub(0, sp_off);
    }

    fn parseVersion(p: *RequestParser) !Request.Version {
        const version_string = "HTTP/1.1";
        if (p.remainingLen() < version_string.len + 2) return error.NeedMore;
        if (!std.mem.eql(u8, p.advance(version_string.len), version_string)) return error.InvalidVersion;
        return .@"1.1";
    }

    fn parseField(p: *RequestParser) !?Request.StringKeyValue.Entry {
        if (p.remainingLen() < 2) return error.NeedMore;
        if (p.data[p.curr] == '\r' and p.data[p.curr + 1] == '\n') {
            _ = p.advance(2);
            return null;
        }

        const name = blk_name: {
            const sep_off: u32 = for (p.data[p.curr..], 0..) |*ch, i| {
                ch.* = std.ascii.toLower(ch.*);
                if (!isFieldNameChar(ch.*)) {
                    if (ch.* != ':') return error.InvalidToken;
                    break @intCast(i);
                }
            } else return error.NeedMore;
            break :blk_name p.advanceByteSlice(sep_off + 1).sub(0, @intCast(sep_off));
        };

        const value = blk_value: {
            // Skip whitespace.
            while (p.curr < p.data.len and p.data[p.curr] == ' ') : (p.curr += 1) {}

            const delim_off: u32 = for (p.data[p.curr..], 0..) |ch, i| {
                if (ch == '\r') break @intCast(i);
            } else return error.NeedMore;

            break :blk_value p.advanceByteSlice(delim_off);
        };

        if (p.remainingLen() < 2) return error.NeedMore;
        if (p.data[p.curr] != '\r' or p.data[p.curr + 1] != '\n') return error.InvalidToken;
        _ = p.advance(2);

        return .{ .k = name, .v = value };
    }

    inline fn advance(p: *RequestParser, n: u32) []u8 {
        assert(p.remainingLen() >= n);
        defer p.curr += n;
        return p.data[p.curr..][0..n];
    }

    inline fn advanceByteSlice(p: *RequestParser, n: u32) Request.ByteSlice {
        assert(p.remainingLen() >= n);
        defer p.curr += n;
        return .{ .ptr = p.curr, .len = n };
    }

    inline fn remainingLen(p: *RequestParser) usize {
        return p.data.len - p.curr;
    }

    // TODO: all of the below functions should be double checked

    fn isMethodChar(ch: u8) bool {
        return std.ascii.isAlphabetic(ch);
    }

    fn isPathChar(ch: u8) bool {
        return ch > ' ';
    }

    fn isFieldNameChar(ch: u8) bool {
        return std.ascii.isAlphabetic(ch) or ch == '-';
    }
};

const test_cases_correct = blk: {
    const tc = @import("test-cases").http1;
    break :blk [_]tc.Request{ tc.request_simple, tc.request_ziglang_docs };
};

test {
    _ = StateMachine;
}
