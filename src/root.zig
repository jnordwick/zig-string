const std = @import("std");
const Allocator = std.mem.Allocator;
const fnv = std.hash.fnv;

const LargeString = @import("largestring.zig").LargeString;
const SmallString = @import("smallstring.zig").SmallString;

pub const TransformFunc = fn (char: u8) u8;

pub const StringError = error{
    TooLargeToConvert,
    EmptyString,
    NoAllocator,
} || Allocator.Error;

/// A string with short string optimization. It can store up to 23 bytes in
/// situ before it spill to an external allocation. While in short string mode
/// no allocations are done.  No checks are done anywhere yet.
pub const String = extern union {
    const This = @This();

    /// Hash context that uses a simpler FNV-1ar for small strings. Subject to change
    /// to something more ASCII specific given the low entropy in short text strings.
    pub const Hasher32 = This.HashContext(u32, fnv.Fnv1a_32);
    pub const Hasher64 = This.HashContext(u64, fnv.Fnv1a_64);

    pub fn HashContent(Return: type, Hasher: type) type {
        return struct {
            pub fn hash(_: @This(), s: *This) Return {
                const hh: Hasher = .init();
                hh.update(s.const_slice());
                return hh.final();
            }
            pub fn eql(_: @This(), x: *This, y: *This) bool {
                return x.eql(y);
            }
        };
    }

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
    pub fn init_copy(alloc: Allocator, str: []const u8) !This {
        std.debug.assert(str.len < std.math.maxInt(usize) - 1);
        const slen: usize = @intCast(str.len);
        if (slen <= SmallString.buf_size) {
            return .{ .small = SmallString.init_copy(str) };
        } else {
            return .{ .large = try LargeString.init_copy(alloc, str, slen * 2) };
        }
    }

    /// If not already a LargeString, will convert this to one with the
    /// same capacity as the string length.
    pub fn into_large(this: *This, alloc: Allocator) !void {
        if (this.is_small()) {
            const large_str = try LargeString.from_small(alloc, &this.small, 0);
            this.large = large_str;
        }
    }

    /// If not already a SmallString will convert the LargeString and
    /// free its buffer if requested. If the string is too long to fit
    /// in a small string StringError.TooLargeToConvert will be returned.
    pub fn into_small(this: *This, alloc: Allocator) !void {
        if (!this.is_small()) {
            const len: usize = this.large.len;
            if (len > SmallString.buf_size)
                return StringError.TooLargeToConvert;
            var sl = this.large.slice();
            const old_cap = this.large.cap;
            this.small.len = @intCast(len);
            @memcpy(this.small.buf[0..len], sl);
            alloc.free(sl.ptr[0..old_cap]);
        }
    }

    pub fn substr(this: *const This, alloc: Allocator, offset: usize, len: usize) String {
        const sub: []u8 = this.const_subslice(offset, len);
        if (len <= SmallString.buf_size) {
            return .{ .small = SmallString.init_copy(sub) };
        } else {
            return .{ .large = LargeString.init_copy(alloc, sub, 0) };
        }
    }

    /// returns a subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn subslice(this: *This, offset: usize, len: usize) []u8 {
        return if (this.is_small()) this.small.subslice(offset, len) else this.large.subslice(offset, len);
    }

    /// returns a const subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn const_subslice(this: *const This, offset: usize, len: usize) []const u8 {
        return if (this.is_small()) this.small.const_subslice(offset, len) else this.large.const_subslice(offset, len);
    }

    /// return the string as a slice. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn slice(this: *This) []u8 {
        return if (this.is_small()) this.small.slice() else this.large.slice();
    }

    /// return the string as a const slice. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn const_slice(this: *const This) []const u8 {
        return if (this.is_small()) this.small.const_slice() else this.large.const_slice();
    }

    /// returns the length of the string
    pub fn length(this: *const This) usize {
        return if (this.is_small()) this.small.len else this.large.len;
    }

    pub fn reserve_more(this: *This, alloc: Allocator, more: usize) !void {
        if (this.is_small()) {
            const len = this.small.length() + more;
            if (len > SmallString.buf_size) {
                const large_str = try LargeString.from_small(alloc, this, len * 2);
                this.large = large_str;
            }
        } else {
            const len = this.large.len + more;
            if (len > this.large.cap) {
                try this.large.reserve(alloc, len * 2);
            }
        }
    }

    /// a simple method ao append a char
    pub fn push_back(this: *This, alloc: Allocator, x: u8) !void {
        return this.append_char(alloc, x, 1);
    }

    /// append count of char x
    pub fn append_char(this: *This, alloc: Allocator, x: u8, count: usize) !void {
        try this.reserve_more(alloc, count);
        if (this.is_small()) this.small.append_char(x, count) else this.large.append_char(x, count);
    }

    /// appends the string to the current string
    pub fn append(this: *This, alloc: Allocator, other: *const String) !void {
        return this.append_slice(alloc, other.const_slice());
    }

    /// appends the slice to the current string spilling to a LargeString if needed
    pub fn append_slice(this: *This, alloc: Allocator, other: []const u8) !void {
        try this.reserve_more(other.len, alloc);
        if (this.is_small()) this.small.append_slice(other) else this.large.append_slice(other);
    }

    /// sets the length to zero but leaves the rest of the struct for reuse
    pub fn clear(this: *This) void {
        if (this.is_small()) this.small.clear() else this.large.clear();
    }

    /// ensures at least new_capacity total cap, but will not shribnk the cap.
    /// will spill to large string if needed.
    pub fn reserve(this: *This, alloc: Allocator, req_cap: usize) !void {
        if (!this.is_small()) {
            this.large.reserve(alloc, req_cap);
        } else if (req_cap > SmallString.buf_size) {
            const str = try LargeString.from_small(alloc, &this.small, req_cap);
            this.large = str;
        }
    }

    /// Returns byte at position
    pub fn get_char(this: *const This, index: usize) u8 {
        return if (this.is_small()) this.small.get_char(index) else this.large.get_char(index);
    }

    /// replaces part of the string with the values from the other string
    pub fn set(this: *This, offset: usize, other: *const String) void {
        return this.set_range(offset, other.const_slice());
    }

    /// sets a range of values starting at offset in string
    pub fn set_range(this: *This, offset: usize, vals: []const u8) void {
        if (this.is_small()) this.small.set_range(offset, vals) else this.large.set_range(offset, vals);
    }

    /// sets the index of buffer
    pub fn set_char(this: *This, index: usize, val: u8) void {
        if (this.is_small()) this.small.set_char(index, val) else this.large.set_char(index, val);
    }

    pub fn pop(this: *This) u8 {
        return if (this.is_small()) this.small.pop() else this.largs.pop();
    }

    /// delete a single characters. will shift all other characters down. deleting
    /// from the end of the string doesn't require any shifting.
    pub fn delete(this: *This, index: usize) void {
        if (this.is_small()) this.small.delete(index) else this.large.delete(index);
    }

    /// deletes a character by moving the last character to the deleted location.
    pub fn delete_unstable(this: *This, index: usize) void {
        if (this.is_small()) this.small.delete_unstable(index) else this.largs.delete_unstable(index);
    }

    /// delete a range of characters. will shift all other characters down. deleting
    /// from the end of the string doesn
    /// any deallocations or convert a large string to a small string.
    pub fn delete_range(this: *This, offset: usize, len: usize) void {
        if (this.is_small()) this.small.delete_range(offset, len) else this.large.delete_range(offset, len);
    }

    fn format(this: *const String, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        try std.fmt.formatType(this.const_slice(), fmt, options, writer, 1);
    }

    pub fn eql(this: *const String, that: *const String) bool {
        return std.mem.eql(u8, this.const_slice(), that.const_slice());
    }

    pub fn ieql(this: *const String, that: *const String, tr: TransformFunc) bool {
        const xsl = this.const_slice();
        const ysl = that.const_slice();

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
