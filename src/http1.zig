const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;

const constants = @import("constants.zig");

pub const Context = struct {
    request: Request = undefined,
    state: enum {
        headers,
        body,
        body_chunked,
    } = .empty,
    buffer: Buffer(constants.http1_buffer_max, u16) = .{},

    pub const ParseError = error{};

    pub fn feed(ctx: *Context, data: []u8) !void {
        switch (ctx.state) {
            .headers => {
                const data_consumed = if (ctx.buffer.readableSlice().len > 0) blk_consume: {
                    // Already have some buffered up, so we append as much as we can to the buffer and try to parse.
                    const data_consumed = ctx.buffer.putSome(data);
                    const consumed = ctx.request.parse(ctx.buffer.readableSlice()) catch |err| return switch (err) {
                        error.NeedMore => if (ctx.buffer.writeableSlice().len == 0) error.TooLarge else error.NeedMore,
                        else => |e| e,
                    };
                    ctx.buffer.consume(consumed);
                    break :blk_consume data_consumed;
                } else ctx.request.parse(data) catch |err| return switch (err) {
                    error.NeedMore => if (data.len <= ctx.buffer.capacity()) blk: {
                        ctx.buffer.appendSliceAssumeCapacity(data);
                        break :blk error.NeedMore;
                    } else error.TooLarge,
                    else => |e| e,
                };

                std.debug.print("method: {s}, path: {s}, version: {s}, headers: {}\n", .{ ctx.request.method, ctx.request.path, @tagName(ctx.request.version), ctx.request.headers.slice() });

                _ = data_consumed;
            },
        }
    }
};

pub const Request = struct {
    method: []u8,
    path: []u8,
    version: enum { @"1.1" },
    headers: std.BoundedArray(Field, constants.http1_headers_count_max),

    fn parse(req: *Request, data: []u8) !usize {
        errdefer req.* = undefined;

        req.headers = .{};
        var parser: Parser = .{
            .req = req,
            .data = data,
            .curr = 0,
        };
        return try parser.parse();
    }

    const Parser = struct {
        req: *Request,
        data: []u8,
        curr: usize,

        fn parse(p: *Parser) !usize {
            assert(p.data.len > 0);

            try p.parseRequestLine();
            while (try p.parseRequestHeader()) {}
            return p.curr;
        }

        fn parseRequestLine(p: *Parser) !void {
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

        fn parseRequestHeader(p: *Parser) !bool {
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

        inline fn advance(p: *Parser, n: usize) []u8 {
            assert(p.remainingLen() >= n);
            defer p.curr += n;
            return p.data[p.curr..][0..n];
        }

        inline fn remainingLen(p: *Parser) usize {
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

    test parse {
        const cases = blk: {
            const tc = @import("test-cases").http1;
            break :blk [_]tc.Request{ tc.request_simple, tc.request_ziglang_docs };
        };

        for (cases) |case| {
            const CaseHeader = @typeInfo(@TypeOf(case.headers)).Pointer.child;

            const buf = try testing.allocator.dupe(u8, case.bytes);
            defer testing.allocator.free(buf);

            var req: Request = undefined;

            const consumed = try req.parse(buf);
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
};

pub const Field = struct {
    name: []const u8,
    value: []const u8,

    pub fn format(value: Field, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}: {s}", .{ value.name, value.value });
    }
};

pub const BufferSize = union(enum) {
    static: usize,
    dynamic,
};

pub fn Buffer(comptime size: BufferSize, comptime IndexType: type) type {
    return struct {
        const Self = @This();

        r_cursor: Index = 0,
        w_cursor: Index = 0,
        buffer_len: switch (size) {
            .static => void,
            .dynamic => Index,
        } = switch (size) {
            .static => {},
            .dynamic => 0,
        },
        buffer: switch (size) {
            .static => |s| [s]u8,
            .dynamic => [*]u8,
        } = undefined,

        pub fn initDynamic(buffer: []u8) Self {
            return switch (size) {
                .static => @compileError("static buffer cannot be initialised as dynamic"),
                .dynamic => blk: {
                    assert(buffer.len <= std.math.maxInt(Index));
                    break :blk .{ .buffer_len = @intCast(buffer.len), .buffer = buffer.ptr };
                },
            };
        }

        pub const Index = blk_index: {
            switch (@typeInfo(IndexType)) {
                .Int => |info| {
                    // Check that indices are unsigned.
                    if (info.signedness != .unsigned) @compileError("index type must be unsigned (got " ++ @typeName(IndexType) ++ ")");
                    // Check that the len/capacity can always be coerced to a usize.
                    if (info.bits > @bitSizeOf(usize)) @compileError("index type is wider than usize (got" ++ @typeName(IndexType) ++ ")");
                    switch (size) {
                        .static => |s| if (std.math.maxInt(IndexType) < s) @compileError(std.fmt.comptimePrint(
                            "index type is too narrow to address static storage ({s} can only address up to {} bytes, but need to address at least {} bytes)",
                            .{ @typeName(IndexType), std.math.maxInt(IndexType), s },
                        )),
                        else => {},
                    }
                    break :blk_index IndexType;
                },
                else => @compileError("index type must be an integer (got " ++ @typeName(IndexType) ++ ")"),
            }
        };

        pub inline fn capacity(b: *const Self) usize {
            return switch (size) {
                .static => |s| s,
                .dynamic => b.buffer_len,
            };
        }

        /// Fully resets the buffer.
        pub fn reset(b: *Self) void {
            b.r_cursor = 0;
            b.w_cursor = 0;
        }

        /// Resets the buffer but keeps the part that hasn't been read yet and moves it to the front.
        pub fn resetAndKeep(b: *Self) void {
            if (b.r_cursor != 0) {
                assert(b.r_cursor <= b.w_cursor);
                const readable = b.readableSlice();
                std.mem.copyForwards(u8, b.storage(), readable);
                b.r_cursor = 0;
                b.w_cursor = readable.len;
            }
        }

        /// Copies as much as it can from `bytes` into the internal buffer, bumping up the write cursor as required. Returns how much was copied.
        pub fn putSome(b: *Self, bytes: []const u8) usize {
            const write_buffer = b.writeableSlice();
            const write_len = @min(write_buffer.len, bytes.len);
            @memcpy(write_buffer[0..write_len], bytes[0..write_len]);
            b.w_cursor += @as(Index, @intCast(write_len));
            assert(b.w_cursor <= b.capacity());
            return write_len;
        }

        /// Consumes part of the read buffer, bumping up the read cursor as required. The `count` parameter must not exceed the size of the readable slice.
        pub fn consume(b: *Self, count: usize) void {
            const read_len = @as(Index, @intCast(count));
            b.r_cursor += read_len;
            assert(b.r_cursor <= b.w_cursor);
        }

        /// The part of the buffer that is available for writes.
        pub inline fn writeableSlice(b: *Self) []u8 {
            return b.storage()[b.w_cursor..b.capacity()];
        }

        /// The part of the buffer that is available for reads.
        pub inline fn readableSlice(b: *Self) []u8 {
            return b.storage()[0..b.r_cursor];
        }

        inline fn storage(b: *Self) []u8 {
            return b.buffer[0..b.capacity()];
        }
    };
}

test {
    _ = Request;
}
