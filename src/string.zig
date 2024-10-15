const std = @import("std");
const Allocator = std.mem.Allocator;

pub const TransformFunc = fn (char: u8) callconv(.Inline) u8;

pub const to_lower_map: [256]u8 = b: {
    var map: [256]u8 = [_]u8{0} ** 256;
    for (0..256) |i| {
        var c: u8 = @intCast(i);
        if (c >= 'A' and c <= 'Z')
            c = (c - 'A') + 'a';
        map[i] = c;
    }
    break :b map;
};

pub const to_upper_map: [256]u8 = b: {
    var map: [256]u8 = [_]u8{0} ** 256;
    for (0..256) |i| {
        var c: u8 = @intCast(i);
        if (c >= 'a' and c <= 'z')
            c = (c - 'a') + 'A';
        map[i] = c;
    }
    break :b map;
};

/// transformer to map uppercase to lowercase.
pub inline fn transform_to_lower(c: u8) u8 {
    return to_lower_map[c];
}

/// transformer to map lowercase to uppercase.
pub inline fn transform_to_upper(c: u8) u8 {
    return to_upper_map[c];
}

/// What is it good for? Absolutely nothing.
pub inline fn transform_ident(c: u8) u8 {
    return c;
}

const SmallStringBase = @import("smallstring.zig").SmallStringBase;
const LargeStringBase = @import("largestring.zig").LargeStringBase;

pub fn sort_less_than(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub const StringError = error{
    TooLargeToConvert,
    NoAllocator,
} || Allocator.Error;

/// A string with short string optimization. It can store up to 23 bytes in
/// situ before it spill to an external allocation. While in short string mode
/// no allocations are done.  No checks are done anywhere yet.
pub const String = StringBase(u64);
pub fn StringBase(Size_: type) type {
    return extern union {
        /// Hash context that uses a simpler hash function more appropriate for
        /// small strings
        pub const HashContext = struct {
            pub fn hash(_: @This(), s: This) This.Size {
                var h: This.Size = 43029;
                for (s.to_const_slice()) |c| {
                    h = (h * 65) ^ c;
                }
                return h;
            }
            pub fn eql(_: @This(), x: This, y: This) bool {
                return std.mem.eql(u8, x.to_const_slice(), y.to_const_slice());
            }
        };

        const This = @This();
        const Size = Size_;

        const LargeString = LargeStringBase(u64);
        const SmallString = SmallStringBase(@sizeOf(LargeString));

        pub const low_mask: u8 = 0b11100000;

        /// the top 3 bits are alawys zero for a small string
        /// any bit set is a large string
        lowbyte: u8,
        small: SmallString,
        large: LargeString,

        pub fn is_small(this: *const This) bool {
            return this.lowbyte & low_mask == 0;
        }

        /// create a new zero length string as a SmallString
        pub fn init() This {
            return .{ .small = SmallString.init() };
        }

        /// create a new string from a slice
        pub fn init_copy(str: []const u8, comptime alloc: anytype) !This {
            std.debug.assert(str.len < std.math.maxInt(Size) - 1);
            const slen: Size = @intCast(str.len);
            if (slen <= SmallString.buf_size) {
                return .{ .small = SmallString.init_copy(str) };
            } else {
                return .{ .large = try LargeString.init_copy(str, slen * 2, alloc) };
            }
        }

        /// If not already a LargeString, will convert this to one with the
        /// same capacity as the string length.
        pub fn into_large(this: *This, comptime alloc: anytype) !void {
            if (this.is_small()) {
                const large_str = try LargeString.from_small(&this.small, 0, alloc);
                this.large = large_str;
            }
        }

        /// If not already a SmallString will convert the LargeString and
        /// free its buffer if requested. If the string is too long to fit
        /// in a small string StringError.TooLargeToConvert will be returned.
        pub fn into_small(this: *This, comptime alloc: anytype) !void {
            if (!this.is_small()) {
                const len: Size = this.large.len;
                if (len >= SmallString.buf_size)
                    return StringError.TooLargeToConvert;
                var slice = this.large.to_slice();
                const old_cap = this.large.cap;
                this.small.len = @intCast(len);
                @memcpy(@as([*]u8, &this.small.data), slice);
                alloc.free(slice.ptr[0..old_cap]);
            }
        }

        pub fn substr(this: *const This, offset: Size, len: Size, comptime alloc: anytype) String {
            const sub: []u8 = this.const_subslice(offset, len);
            if (len <= SmallString.buf_size) {
                return .{ .small = SmallString.init_copy(sub) };
            } else {
                return .{ .large = LargeString.init_copy(sub, 0, alloc) };
            }
        }

        /// returns a subslice of the string. if the string is ever converted from small to large or has to be
        /// reallocated to a different memory location, this slice will be invaid.
        pub fn subslice(this: *This, offset: Size, len: Size) []u8 {
            return if (this.is_small()) this.small.subslice(offset, len) else this.large.subslice(offset, len);
        }

        /// returns a const subslice of the string. if the string is ever converted from small to large or has to be
        /// reallocated to a different memory location, this slice will be invaid.
        pub fn const_subslice(this: *const This, offset: Size, len: Size) []const u8 {
            return if (this.is_small()) this.small.const_subslice(offset, len) else this.large.const_subslice(offset, len);
        }

        /// return the string as a slice. if the string is ever converted from small to large or has to be
        /// reallocated to a different memory location, this slice will be invaid.
        pub fn to_slice(this: *This) []u8 {
            return if (this.is_small()) this.small.to_slice() else this.large.to_slice();
        }

        /// return the string as a const slice. if the string is ever converted from small to large or has to be
        /// reallocated to a different memory location, this slice will be invaid.
        pub fn to_const_slice(this: *const This) []const u8 {
            return if (this.is_small()) this.small.to_const_slice() else this.large.to_const_slice();
        }

        /// returns the length of the string
        pub fn length(this: *const This) Size {
            return if (this.is_small()) this.small.len else this.large.len;
        }

        pub fn reserve_more(this: *This, more: Size, comptime alloc: ?Allocator) !void {
            if (this.isSmallString()) {
                const len = this.small.length() + more;
                if (len > SmallString.buf_size) {
                    if (alloc) |a| {
                        const large_str = try LargeString.from_small(this, len * 2, a);
                        this.large = large_str;
                    } else {
                        return StringError.NoAllocator;
                    }
                }
            } else {
                const len = this.large.len + more;
                if (len > this.large.cap) {
                    try this.large.reserve(len * 2, alloc);
                }
            }
        }

        pub fn push_back(this: *This, x: u8, comptime alloc: ?Allocator) !void {
            try this.reserve_more(@sizeOf(x), alloc);
            if (this.is_small()) this.small.push_back(x) else this.large.push_back_noalloc();
        }

        pub fn append1(this: *This, x: u8, count: Size, comptime alloc: ?Allocator) !void {
            try this.reserve_more(count, alloc);
            if (this.isSmallString()) this.small.append1(x, count) else this.large.append1_noalloc(x, count);
        }

        /// appends the string to the current string spilling to a LargeString if needed
        pub fn append(this: *This, other: *const String, comptime alloc: ?Allocator) !void {
            return this.append_slice(other.to_const_slice(), alloc);
        }

        /// appends the slice to the current string spilling to a LargeString if needed
        pub fn append_slice(this: *This, other: []const u8, comptime alloc: ?Allocator) !void {
            try this.reserve_more(other.len, alloc);
            if (this.isSmallString()) this.small.append(other) else this.large.append_noalloc(other);
        }

        /// sets the length to zero but leaves the rest of the struct for reuse
        pub fn clear(this: *This) void {
            if (this.isSmallStrig()) this.small.clear() else this.large.clear();
        }

        /// ensures at least new_capacity total cap, but will not shribnk the cap.
        /// will spill to large string if needed.
        pub fn reserve(this: *This, new_cap: Size, comptime alloc: ?Allocator) !void {
            if (!this.is_small()) {
                this.large.reserve(new_cap, alloc);
            } else if (new_cap > SmallString.buf_size) {
                const str = try LargeString.from_small(&this.small, new_cap, alloc);
                this.large = str;
            }
        }

        /// Returns byte at position
        pub fn get1(this: *const This, index: Size) u8 {
            return if (this.is_small()) this.small.get(index) else this.large.get(index);
        }

        /// replaces part of the string with the values from the other string
        pub fn set(this: *This, offset: Size, other: *const String) void {
            return this.set_range(offset, other.to_const_slice());
        }

        /// sets a range of values starting at offset in string
        pub fn set_range(this: *This, offset: Size, vals: []const u8) void {
            if (this.is_small()) this.small.set_range(offset, vals) else this.large.set_range(offset, vals);
        }

        /// sets the index of buffer
        pub fn set1(this: *This, index: Size, val: u8) void {
            if (this.is_small()) this.small.set1(index, val) else this.large.set1(index, val);
        }

        pub fn pop(this: *This) u8 {
            if (this.is_small()) this.small.pop() else this.largs.pop();
        }

        /// delete a single characters. will shift all other characters down. deleting
        /// from the end of the string doesn't require any shifting.
        pub fn delete(this: *This, index: Size) void {
            if (this.is_small()) this.small.delete(index) else this.large.delete(index);
        }

        pub fn delete_unstable(this: *This, index: Size) void {
            if (this.is_small()) this.small.delete_unstable(index) else this.largs.delete_unstable(index);
        }

        /// delete a range of characters. will shift all other characters down. deleting
        /// from the end of the string doesn't require any shifting. This will not cause
        /// any deallocations or convert a large string to a small string.
        pub fn delete_range(this: *This, offset: Size, len: Size) void {
            if (this.is_small()) this.small.delete_range(offset, len) else this.large.delete_range(offset, len);
        }

        fn format(this: *const String, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
            try std.fmt.formatType(this.to_const_slice(), fmt, options, out_stream, 1);
        }

        pub fn eql(this: *const String, that: *const String) bool {
            return std.mem.eql(this.to_const_slice(), that, to_const_slice());
        }

        pub fn ieql(this: *const String, that: *const String, tr: TransformFunc) bool {
            const xsl = this.to_const_slice();
            const ysl = that.to_const_slice();

            if (xsl.len != ysl.len)
                return false;
            for (xsl, ysl) |x, y| {
                if (tr(x) != tr(y))
                    return false;
            }
            return true;
        }

        pub fn transform(this: *String, tr: TransformFunc) void {
            var sl = this.to_slice();
            for (0..sl.len) |i| {
                sl[i] = tr(sl[i]);
            }
        }
    };
}
