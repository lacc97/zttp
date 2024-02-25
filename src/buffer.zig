const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;

const xev = @import("xev");

pub const alignment = std.atomic.cache_line;

pub const BufferPool = struct {
    gpa: std.mem.Allocator,

    pools: []Pool,

    min_size_bits: u6,

    pub const Options = struct {
        /// The log2 minimum buffer size (default: 12 -> 4 KiB).
        min_size_bits: u6 = 12,

        /// The log2 maximum buffer size (default: 22 -> 4 MiB)
        max_size_bits: u6 = 22,
    };

    const Pool = struct {
        const Link = struct { next: ?*Link = null };

        freelist: ?*Link = null,
        buffer_size: usize,

        pub fn deinit(p: *Pool, gpa: std.mem.Allocator) void {
            while (p.pop()) |raw_buf| {
                const buf: [*]align(alignment) u8 = @ptrCast(raw_buf);
                gpa.free(buf[0..p.buffer_size]);
            }
        }

        pub fn alloc(p: *Pool, gpa: std.mem.Allocator) error{OutOfMemory}!*RawBuffer {
            if (p.pop()) |raw_buf| return raw_buf;
            return p.allocNew(gpa);
        }

        pub const free = push;

        fn push(p: *Pool, raw_buf: *RawBuffer) void {
            assert(bufferAllocationLength(raw_buf.buf_len) == p.buffer_size);

            const link = raw_buf.castUserData(Link);
            link.next = p.freelist;
            p.freelist = link;
        }

        fn pop(p: *Pool) ?*RawBuffer {
            if (p.freelist) |l| {
                const buffer = RawBuffer.fromUserData(Link, l);
                p.freelist = l.next;
                buffer.__userd = undefined;
                return buffer;
            }
            return null;
        }

        fn allocNew(p: *Pool, gpa: std.mem.Allocator) error{OutOfMemory}!*RawBuffer {
            @setCold(true);

            const buf = try gpa.alignedAlloc(u8, alignment, p.buffer_size);
            assert(buf.len > @sizeOf(RawBuffer));
            const raw_buf: *RawBuffer = @ptrCast(buf.ptr);
            raw_buf.buf_len = p.buffer_size - @sizeOf(RawBuffer);
            return raw_buf;
        }
    };

    pub fn init(gpa: std.mem.Allocator, opts: Options) error{OutOfMemory}!BufferPool {
        assert(opts.min_size_bits >= 10); // at least 1 KiB
        assert(opts.max_size_bits >= opts.min_size_bits);

        const pools_len: usize = 1 + (opts.max_size_bits - opts.min_size_bits);
        const pools = try gpa.alloc(Pool, pools_len);
        for (pools, 0..) |*pool, i| pool.* = .{
            .buffer_size = @as(usize, 1) << (@as(u6, @intCast(i)) + opts.min_size_bits),
        };
        return .{ .gpa = gpa, .pools = pools, .min_size_bits = opts.min_size_bits };
    }

    pub fn deinit(p: *BufferPool) void {
        for (p.pools) |*pool| pool.deinit(p.gpa);
        p.gpa.free(p.pools);
    }

    pub fn alloc(p: *BufferPool, req_min_len: usize) error{OutOfMemory}!Buffer {
        const min_len = bufferAllocationLength(req_min_len);
        const min_len_bits = @max(p.min_size_bits, std.math.log2_int_ceil(usize, min_len));
        const pool_index = min_len_bits - p.min_size_bits;
        if (pool_index >= p.pools.len) return error.OutOfMemory;
        const raw = try p.pools[pool_index].alloc(p.gpa);
        return .{ .raw = raw, .len = raw.buf_len };
    }

    pub fn free(p: *BufferPool, buf: Buffer) void {
        assert(buf.len == buf.raw.buf_len);
        const len = bufferAllocationLength(buf.raw.buf_len);
        if (!std.math.isPowerOfTwo(len)) panic(
            "invalid buffer length: {} + {} = {} is not a power of 2",
            .{ buf.raw.buf_len, @sizeOf(RawBuffer), len },
        );
        const len_bits = std.math.log2_int_ceil(usize, len);
        if (len_bits < p.min_size_bits or (len_bits - p.min_size_bits) >= p.pools.len) panic(
            "invalid buffer length: log2 of ({} + {}) = {} does not fit in allowed size interval [{}; {}]",
            .{
                buf.raw.buf_len,
                @sizeOf(RawBuffer),
                len_bits,
                p.min_size_bits,
                p.min_size_bits + p.pools.len,
            },
        );

        const pool_index = len_bits - p.min_size_bits;
        p.pools[pool_index].free(buf.raw);
    }

    fn bufferAllocationLength(len: usize) usize {
        // Need to account for the extra space taken up by the buffer header.
        return len + @sizeOf(RawBuffer);
    }
};

pub const Buffer = struct {
    raw: *RawBuffer,

    /// Stored inline to avoid a potentially expensive cache miss when directly accessing raw.buf_len.
    len: usize,

    pub const Slice = []align(alignment) u8;

    pub inline fn intoReadBuffer(b: Buffer) xev.ReadBuffer {
        return .{ .slice = b.slice() };
    }
    pub inline fn fromReadBuffer(rb: xev.ReadBuffer) Buffer {
        const b = Buffer{
            .raw = RawBuffer.fromPtr(@alignCast(rb.slice.ptr)),
            .len = rb.slice.len,
        };
        assert(b.len == b.raw.buf_len);
        return b;
    }

    pub inline fn intoWriteBuffer(b: Buffer) xev.WriteBuffer {
        return .{ .slice = b.slice() };
    }
    pub inline fn fromWriteBuffer(wb: xev.WriteBuffer) Buffer {
        const b = Buffer{
            .raw = RawBuffer.fromPtr(@alignCast(@constCast(wb.slice.ptr))),
            .len = wb.slice.len,
        };
        assert(b.len == b.raw.buf_len);
        return b;
    }

    pub inline fn slice(b: Buffer) Slice {
        assert(b.len == b.raw.buf_len);
        return b.raw.ptr()[0..b.len];
    }

    pub inline fn castUserData(b: Buffer, comptime T: type) *T {
        return b.raw.castUserData(T);
    }
};

const RawBuffer = extern struct {
    __align: void align(alignment) = {},
    buf_len: usize,
    __userd: UserData align(user_data_alignment) = undefined,

    pub const user_data_alignment = @alignOf(usize);

    pub const UserData = [alignment - @sizeOf(usize)]u8;

    pub inline fn ptr(b: *RawBuffer) [*]align(alignment) u8 {
        return @ptrFromInt(@intFromPtr(b) + @sizeOf(RawBuffer));
    }

    pub inline fn fromPtr(buf_ptr: [*]align(alignment) u8) *RawBuffer {
        return @ptrFromInt(@intFromPtr(buf_ptr) - @sizeOf(RawBuffer));
    }

    pub inline fn castUserData(b: *RawBuffer, comptime T: type) *align(user_data_alignment) T {
        assert(@sizeOf(T) <= @sizeOf(UserData));
        return @ptrCast(&b.__userd);
    }

    pub inline fn fromUserData(comptime T: type, ud: *align(user_data_alignment) T) *RawBuffer {
        assert(@sizeOf(T) <= @sizeOf(UserData));
        return @alignCast(@fieldParentPtr(
            RawBuffer,
            "__userd",
            @as(*align(user_data_alignment) UserData, @ptrCast(ud)),
        ));
    }
};

test {
    const testing = std.testing;

    var pool = try BufferPool.init(testing.allocator, .{
        .min_size_bits = 10, // 1 KiB
        .max_size_bits = 20, // 1 MiB
    });
    defer pool.deinit();

    // Allocations work and give at least the same size as requested.
    {
        const buf = try pool.alloc(1024);
        defer pool.free(buf);
        try testing.expect(buf.slice().len >= 1024);
    }

    {
        const buf = try pool.alloc(512 * 1024);
        defer pool.free(buf);
        try testing.expect(buf.slice().len >= 512 * 1024);
    }

    {
        const buf = try pool.alloc(512 * 1024);
        defer pool.free(buf);
        try testing.expect(buf.slice().len >= 512 * 1024);
    }

    // Smaller than minimum allocations work.

    {
        const buf = try pool.alloc(512);
        defer pool.free(buf);
        try testing.expect(buf.slice().len >= 512);
    }

    // Larger than maximum fails.

    {
        try testing.expectError(
            error.OutOfMemory,
            pool.alloc(2 * 1024 * 1024),
        );
    }

    // The actual maximum doesn't work because it needs space for the buffer header.
    {
        try testing.expectError(
            error.OutOfMemory,
            pool.alloc(1 * 1024 * 1024),
        );
    }
}
