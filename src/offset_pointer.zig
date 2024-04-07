const std = @import("std");
const assert = std.debug.assert;

pub fn Ptr(comptime T: type, comptime Offset: type, comptime addressing: Addressing) type {
    verifyInteger(Offset);

    const spec = addressing.spec(T);

    return packed struct {
        const Self = @This();

        inner: Offset,

        pub inline fn reify(
            ptr: Self,
            buffer: spec.Buffer,
        ) @TypeOf(spec.reify(ptr.inner, buffer)) {
            return spec.reify(ptr.inner, buffer);
        }
        pub inline fn reifyConst(
            ptr: Self,
            buffer: spec.BufferConst,
        ) @TypeOf(spec.reify(ptr.inner, buffer)) {
            return spec.reify(ptr.inner, buffer);
        }
    };
}

pub fn Slice(comptime T: type, comptime Offset: type, comptime Len: type, comptime addressing: Addressing) type {
    verifyInteger(Offset);
    verifyInteger(Len);

    const spec = addressing.spec(T);

    return packed struct {
        const Self = @This();

        ptr: Offset,
        len: Len,

        pub inline fn sub(slice: Self, idx: Offset, len: Len) Self {
            switch (addressing) {
                .byte => {
                    assert(@as(usize, idx) <= @as(usize, slice.len) * @sizeOf(T));
                    assert(@as(usize, len) <= (@as(usize, slice.len) * @sizeOf(T)) - @as(usize, idx));
                },
                .type => {
                    assert(@as(usize, idx) <= @as(usize, slice.len));
                    assert(@as(usize, len) <= @as(usize, slice.len) - @as(usize, idx));
                },
            }
            return .{ .ptr = slice.ptr + idx, .len = len };
        }

        pub inline fn reify(
            slice: Self,
            buffer: spec.Buffer,
        ) @TypeOf(spec.reifySlice(slice.inner, slice.len, buffer)) {
            return spec.reifySlice(slice.inner, slice.len, buffer);
        }
        pub inline fn reifyConst(
            slice: Self,
            buffer: spec.BufferConst,
        ) @TypeOf(spec.reifySlice(slice.ptr, slice.len, buffer)) {
            return spec.reifySlice(slice.ptr, slice.len, buffer);
        }
    };
}

pub const Addressing = enum {
    byte,
    type,

    fn spec(comptime addr: Addressing, comptime T: type) type {
        return switch (addr) {
            .byte => struct {
                pub const Buffer = []u8;
                pub const BufferConst = []const u8;

                pub inline fn reify(
                    off: anytype,
                    buffer: anytype,
                ) @TypeOf(std.mem.bytesAsValue(buffer[@as(usize, off)..][0..@sizeOf(T)])) {
                    return std.mem.bytesAsValue(T, buffer[@as(usize, off)..][0..@sizeOf(T)]);
                }
                pub inline fn reifySlice(
                    off: anytype,
                    len: anytype,
                    buffer: anytype,
                ) @TypeOf(std.mem.bytesAsSlice(T, buffer[@as(usize, off)..][0 .. @as(usize, len) * @sizeOf(T)])) {
                    return std.mem.bytesAsSlice(T, buffer[@as(usize, off)..][0 .. @as(usize, len) * @sizeOf(T)]);
                }
            },
            .type => struct {
                pub const Buffer = []T;
                pub const BufferConst = []const T;

                pub inline fn reify(
                    off: anytype,
                    buffer: anytype,
                ) @TypeOf(&buffer[@as(usize, off)]) {
                    return &buffer[@as(usize, off)];
                }
                pub inline fn reifySlice(
                    off: anytype,
                    len: anytype,
                    buffer: anytype,
                ) @TypeOf(buffer[@as(usize, off)..][0..@as(usize, len)]) {
                    return buffer[@as(usize, off)..][0..@as(usize, len)];
                }
            },
        };
    }
};

fn verifyInteger(comptime Int: type) void {
    switch (@typeInfo(Int)) {
        .Int => |info| {
            if (info.signedness != .unsigned) @compileError("offset type must be an unsigned integer");
            if (info.bits > @bitSizeOf(usize)) @compileError("type must not be larger than usize");
        },
        else => @compileError("offset type must be an unsigned integer"),
    }
}
