const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const constants = @import("constants.zig");

const Request = @This();

data: []const u8,

_method: ByteSlice,
_path: ByteSlice,
_version: Version,
_headers: StringKeyValue,

pub const Version = enum { @"1.1" };

pub const ByteSlice = @import("offset_pointer.zig").Slice(u8, u32, u32, .type);

pub fn method(req: Request) []const u8 {
    return req._method.reifyConst(req.data);
}
pub fn path(req: Request) []const u8 {
    return req._path.reifyConst(req.data);
}
pub fn version(req: Request) Version {
    return req._version;
}
pub fn headers(req: Request) StringKeyValue.ReifyConst {
    return req._headers.reifyConst(req.data);
}

pub fn dump(req: Request, writer: anytype) !void {
    try writer.print("{s} {s} HTTP/{s}\n", .{ req.method(), req.path(), @tagName(req.version()) });
    var it = req.headers().iterate();
    while (it.next()) |h| try writer.print("{s}: {s}\n", .{ h.k, h.v });
    try writer.writeByte('\n');
}

pub const StringKeyValue = struct {
    buf: []Entry = &.{},

    pub const KV = struct { k: []const u8, v: []const u8 };

    pub const Entry = struct {
        k: ByteSlice,
        v: ByteSlice,

        pub fn reifyConst(e: Entry, buffer: []const u8) KV {
            return .{
                .k = e.k.reifyConst(buffer),
                .v = e.v.reifyConst(buffer),
            };
        }
    };

    pub inline fn reifyConst(smap: StringKeyValue, data: []const u8) ReifyConst {
        return .{ .smap = smap.buf, .data = data };
    }

    pub const ReifyConst = struct {
        smap: []const Entry,
        data: []const u8,

        pub fn get(smap: ReifyConst, key: []const u8) ?KV {
            return for (smap.smap) |e| {
                const k = e.k.reifyConst(smap.data);
                if (std.mem.eql(u8, k, key)) {
                    const v = e.v.reifyConst(smap.data);
                    break .{ .k = k, .v = v };
                }
            } else null;
        }

        pub fn iterate(smap: ReifyConst) Iterator {
            return .{ .idx = 0, .buf = smap.smap, .data = smap.data };
        }

        pub const Iterator = struct {
            idx: usize,
            buf: []const Entry,
            data: []const u8,

            pub fn next(it: *Iterator) ?KV {
                return while (it.idx < it.buf.len) {
                    defer it.idx += 1;
                    break it.buf[it.idx].reifyConst(it.data);
                } else return null;
            }
        };
    };
};
