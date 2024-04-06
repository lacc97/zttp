const std = @import("std");

pub const http1 = struct {
    pub const Request = struct {
        bytes: []const u8,

        method: []const u8,
        path: []const u8,
        headers: []const Header,

        pub const Header = struct {
            name: []const u8,
            value: []const u8,

            fn sorted(comptime hdrs: []const Header) []const Header {
                var hdrs_sorted_mut: [hdrs.len]Header = undefined;
                @memcpy(&hdrs_sorted_mut, hdrs);
                std.sort.block(Header, &hdrs_sorted_mut, SortContext{}, SortContext.lessThan);
                const hdrs_sorted = hdrs_sorted_mut;
                return &hdrs_sorted;
            }

            pub const SortContext = struct {
                pub fn lessThan(_: @This(), lhs: Header, rhs: Header) bool {
                    return switch (std.mem.order(u8, lhs.name, rhs.name)) {
                        .lt => true,
                        .gt => false,
                        .eq => std.mem.order(u8, lhs.value, rhs.value) == .lt,
                    };
                }
            };
        };
    };

    pub const request_simple: Request = .{
        .bytes = "GET / HTTP/1.1\r\nConnection: close\r\n\r\n",

        .method = "GET",
        .path = "/",
        .headers = Request.Header.sorted(&.{
            .{ .name = "connection", .value = "close" },
        }),
    };

    pub const request_ziglang_docs: Request = .{
        .bytes = @embedFile("req_ziglang_docs.txt"),

        .method = "GET",
        .path = "/documentation/master/std/",
        .headers = Request.Header.sorted(&.{
            .{ .name = "host", .value = "ziglang.org" },
            .{ .name = "user-agent", .value = "Mozilla/5.0 (Windows NT 10.0; rv:124.0) Gecko/20100101 Firefox/124.0" },
            .{ .name = "accept", .value = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8" },
            .{ .name = "accept-language", .value = "en-US,en;q=0.5" },
            .{ .name = "accept-encoding", .value = "gzip, deflate, br" },
            .{ .name = "dnt", .value = "1" },
            .{ .name = "sec-gpc", .value = "1" },
            .{ .name = "connection", .value = "keep-alive" },
            .{ .name = "upgrade-insecure-requests", .value = "1" },
            .{ .name = "sec-fetch-dest", .value = "document" },
            .{ .name = "sec-fetch-mode", .value = "navigate" },
            .{ .name = "sec-fetch-site", .value = "none" },
            .{ .name = "sec-fetch-user", .value = "?1" },
            .{ .name = "if-modified-since", .value = "Mon, 01 Apr 2024 21:21:37 GMT" },
            .{ .name = "if-none-match", .value = "\"5571206c9f13b9cf72cd45fa0d77730f\"" },
            .{ .name = "te", .value = "trailers" },
        }),
    };
};
