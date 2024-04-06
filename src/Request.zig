const std = @import("std");

const constants = @import("constants.zig");

const Request = @This();

method: []u8,
path: []u8,
version: enum { @"1.1" },

headers: std.BoundedArray(Header, constants.http1_headers_count_max),

pub const Header = struct { name: []const u8, value: []const u8 };

pub const HeaderByNameIterator = struct {
    idx: usize,
    hdr: []const Header,
    name: []const u8,

    pub fn next(it: *HeaderByNameIterator) ?Header {
        return hdr_loop: while (it.idx < it.hdr.len) : (it.idx += 1) {
            const h = it.hdr[it.idx];

            // -- compare name
            if (h.name.len != it.name.len) continue :hdr_loop;
            for (h.name, it.name) |ch, cn| {
                if (std.ascii.toLower(ch) != std.ascii.toLower(cn)) continue :hdr_loop;
            }

            it.idx += 1;
            break :hdr_loop h;
        } else null;
    }
};

pub fn getHeaders(req: *const Request) []const Header {
    return req.headers.slice();
}

pub fn getHeaderByName(req: *const Request, name: []const u8) HeaderByNameIterator {
    return .{ .idx = 0, .hdr = req.headers.slice(), .name = name };
}
