const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const constants = @import("constants.zig");

const Request = @This();

method: []u8,
path: []u8,
version: enum { @"1.1" },

headers: HeaderMap,

pub const Header = struct { name: []const u8, value: []const u8 };

pub fn dump(req: Request, writer: anytype) !void {
    try writer.print("{s} {s} HTTP/{s}\n", .{ req.method, req.path, @tagName(req.version) });
    var it = req.headers.iterator();
    while (it.next()) |h| try writer.print("{s}: {s}\n", .{ h.name, h.value });
    try writer.writeByte('\n');
}

pub const HeaderMap = struct {
    trie: Index = .empty,
    trie_storage: std.BoundedArray(Entry, constants.http1_headers_count_max) = .{},

    const Entry = struct {
        child: [4]Index = [_]Index{.empty} ** 4,
        header: Header,
    };
    const Index = enum(u16) { empty = std.math.maxInt(u16), _ };

    comptime {
        assert(constants.http1_headers_count_max < @intFromEnum(Index.empty));
    }

    pub fn len(hm: *const HeaderMap) u16 {
        return @intCast(hm.trie_storage.len);
    }

    pub fn find(hm: *const HeaderMap, name: []const u8) ?Header {
        var it = hm.findMany(name);
        const header = it.next();
        return header;
    }

    pub fn findSingle(hm: *const HeaderMap, name: []const u8) error{Duplicate}!?Header {
        var it = hm.findMany(name);
        const header = it.next();
        if (it.next()) |_| return error.Duplicate;
        return header;
    }

    pub fn findMany(hm: *const HeaderMap, name: []const u8) FindIterator {
        return .{
            .i = hm.trie,
            .h = hash(name),
            .name = name,
            .trie = hm,
        };
    }

    pub fn add(hm: *HeaderMap, name: []const u8, value: []const u8) error{OutOfMemory}!void {
        const entry_new_index: Index = @enumFromInt(@as(u16, @intCast(hm.trie_storage.len)));
        const entry_new = hm.trie_storage.addOne() catch return error.OutOfMemory;
        entry_new.* = .{ .header = .{ .name = name, .value = value } };

        var l: *Index = &hm.trie;
        var h = hash(name);
        while (l.* != .empty) : (h >>= 2) l = &hm.entry(l.*).child[h & 0b11];
        l.* = entry_new_index;
    }

    pub const FindIterator = struct {
        i: Index,
        h: u64,
        name: []const u8,
        trie: *const HeaderMap,

        pub fn next(it: *FindIterator) ?Header {
            // We look up in the same way we add a new entry, which means we preserve insertion order.
            return while (it.i != .empty) {
                const ent = it.trie.entryConst(it.i);
                defer {
                    it.i = ent.child[it.h & 0b11];
                    it.h >>= 2;
                }
                if (!eql(it.name, ent.header.name)) continue;
                break ent.header;
            } else null;
        }
    };

    pub fn iterator(hm: *const HeaderMap) Iterator {
        return .{ .i = 0, .entries = hm.trie_storage.constSlice() };
    }

    pub const Iterator = struct {
        i: usize,
        entries: []const Entry,

        pub fn next(it: *Iterator) ?Header {
            return while (it.i < it.entries.len) {
                defer it.i += 1;
                break it.entries[it.i].header;
            } else null;
        }
    };

    inline fn entry(hm: *HeaderMap, index: Index) *Entry {
        assert(index != .empty);
        return &hm.trie_storage.slice()[@intFromEnum(index)];
    }
    inline fn entryConst(hm: *const HeaderMap, index: Index) *const Entry {
        assert(index != .empty);
        return &hm.trie_storage.constSlice()[@intFromEnum(index)];
    }

    fn hash(s: []const u8) u64 {
        var hasher = std.hash.Wyhash.init(0); // TODO: seed
        hasher.update(s);
        return hasher.final();
    }

    fn eql(lhs: []const u8, rhs: []const u8) bool {
        return std.mem.eql(u8, lhs, rhs);
    }

    test {
        var hm: HeaderMap = .{};

        try testing.expectEqual(@as(?Header, null), hm.find("accept-encoding"));

        try hm.add("accept-encoding", "gzip");
        try testing.expectEqualDeep(@as(?Header, .{ .name = "accept-encoding", .value = "gzip" }), hm.find("accept-encoding"));
    }
};
