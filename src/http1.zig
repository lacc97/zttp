const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const constants = @import("constants.zig");

const Request = @import("Request.zig");

pub const StateMachine = union(enum) {
    headers,
    body: struct {
        cur: u64 = 0,
        len: u64,
    },
    body_chunked,

    pub fn process(sm: *StateMachine, data: []u8) !usize {
        return switch (sm.*) {
            .headers => blk_headers: {
                var req: Request = undefined;
                const consumed = try parseRequestLineAndHeaders(&req, data);
                req.getHeadersByName();
                break :blk_headers consumed;
            },
        };
    }
};

fn parseRequestLineAndHeaders(req: *Request, data: []u8) !usize {
    assert(data.len > 0);

    req.headers = .{};

    var p: RequestParser = .{
        .req = req,
        .data = data,
        .curr = 0,
    };

    try p.parseRequestLine();
    while (try p.parseRequestHeader()) {}
    return p.curr;
}

test parseRequestLineAndHeaders {
    const cases = blk: {
        const tc = @import("test-cases").http1;
        break :blk [_]tc.Request{ tc.request_simple, tc.request_ziglang_docs };
    };

    for (cases) |case| {
        const CaseHeader = @typeInfo(@TypeOf(case.headers)).Pointer.child;

        const buf = try testing.allocator.dupe(u8, case.bytes);
        defer testing.allocator.free(buf);

        var req: Request = undefined;

        const consumed = try parseRequestLineAndHeaders(&req, buf);
        try testing.expectEqual(@as(usize, case.bytes.len), consumed);

        try testing.expectEqualStrings(case.method, req.method);
        try testing.expectEqualStrings(case.path, req.path);

        const headers = try testing.allocator.alloc(CaseHeader, req.headers.slice().len);
        defer testing.allocator.free(headers);

        for (headers, req.headers.slice()) |*h, rh| h.* = .{ .name = rh.name, .value = rh.value };
        std.sort.pdq(CaseHeader, headers, CaseHeader.SortContext{}, CaseHeader.SortContext.lessThan);

        for (0..@max(headers.len, case.headers.len)) |i| {
            const name_expected = if (case.headers.len > i) case.headers[i].name else "";
            const value_expected = if (case.headers.len > i) case.headers[i].value else "";
            const name_got = if (headers.len > i) headers[i].name else "";
            const value_got = if (headers.len > i) headers[i].value else "";

            try testing.expectEqualStrings(name_expected, name_got);
            try testing.expectEqualStrings(value_expected, value_got);
        }
    }
}

const RequestParser = struct {
    req: *Request,
    data: []u8,
    curr: usize,

    fn parseRequestLine(p: *RequestParser) !void {
        { // -- method
            const sp_off = for (p.data[p.curr..], 0..) |ch, i| {
                if (!isMethodChar(ch)) {
                    if (ch != ' ') return error.InvalidToken;
                    break i;
                }
            } else return error.NeedMore;
            p.req.method = p.advance(sp_off + 1)[0..sp_off];
        }

        { // -- path
            const sp_off = for (p.data[p.curr..], 0..) |ch, i| {
                if (!isPathChar(ch)) {
                    if (ch != ' ') return error.InvalidToken;
                    break i;
                }
            } else return error.NeedMore;
            p.req.path = p.advance(sp_off + 1)[0..sp_off];
        }

        { // -- version
            const version = "HTTP/1.1";
            if (p.remainingLen() < version.len + 2) return error.NeedMore;
            if (!std.mem.eql(u8, p.advance(version.len), version)) return error.InvalidVersion;
            p.req.version = .@"1.1";
            if (!std.mem.eql(u8, p.advance(2), "\r\n")) return error.InvalidToken;
        }
    }

    fn parseRequestHeader(p: *RequestParser) !bool {
        if (p.remainingLen() < 2) return error.NeedMore;
        if (p.data[p.curr] == '\r' and p.data[p.curr + 1] == '\n') {
            _ = p.advance(2);
            return false;
        }

        const name = blk_name: {
            const sep_off = for (p.data[p.curr..], 0..) |*ch, i| {
                ch.* = std.ascii.toLower(ch.*);
                if (!isFieldNameChar(ch.*)) {
                    if (ch.* != ':') return error.InvalidToken;
                    break i;
                }
            } else return error.NeedMore;
            break :blk_name p.advance(sep_off + 1)[0..sep_off];
        };

        const value = blk_value: {
            // Skip whitespace.
            while (p.curr < p.data.len and p.data[p.curr] == ' ') : (p.curr += 1) {}

            const delim_off = for (p.data[p.curr..], 0..) |ch, i| {
                if (ch == '\r') break i;
            } else return error.NeedMore;

            break :blk_value p.advance(delim_off);
        };

        if (p.remainingLen() < 2) return error.NeedMore;
        if (p.data[p.curr] != '\r' or p.data[p.curr + 1] != '\n') return error.InvalidToken;
        _ = p.advance(2);

        p.req.headers.append(.{ .name = name, .value = value }) catch return error.TooManyHeaders;
        return true;
    }

    inline fn advance(p: *RequestParser, n: usize) []u8 {
        assert(p.remainingLen() >= n);
        defer p.curr += n;
        return p.data[p.curr..][0..n];
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
