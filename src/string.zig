const std = @import("std");
const Allocator = std.mem.Allocator;

const SmallString = @import("smallstring.zig").SmallString;
const LargeString = @import("largestring.zig").LargeString;

pub const StringError = error{
    TooLargeToConvert,
    NoAllocator,
} || Allocator.Error;

pub const String = extern union {
    lowbyte: u8,
    small: SmallString,
    large: LargeString,

    const This = @This();

    pub fn isLargeStr(this: *const This) bool {
        return this.lowbyte & 1 == 0;
    }

    pub fn isSmallStr(this: *const This) bool {
        return this.lowbyte & 1 == 1;
    }

    /// create a new zero length string as a SmallString
    pub fn init() This {
        return .{ .small = SmallString.init() };
    }

    /// craete a new string from a slice
    /// str: the slice to copy.
    /// alloc: can be null if you know the string will fit in a
    /// SmallString and the allocator will not be needed.
    pub fn init_copy(str: []const u8, alloc: ?*const Allocator) !This {
        if (str.len <= SmallString.buf_size) {
            return .{ .small = SmallString.init_copy(str) };
        } else {
            if (alloc) |a| {
                return .{ .large = try LargeString.init_copy(str, str.len * 2, a) };
            } else {
                return StringError.NoAllocator;
            }
        }
    }

    /// If not already a LargeString, will convert this to one with the
    /// same capacity as the strig length.
    pub fn into_large(this: *This, alloc: *const Allocator) !void {
        if (this.isSmallStr()) {
            var large_str = try LargeString.from_small(&this.small, 0, alloc);
            this.large = large_str;
        }
    }

    /// If not already a SmallString will convert the LargeString and
    /// free its buffer if requested. If the string is too long to fir
    /// in a small string StringError.TooLargeToConvert will be returned.
    /// alloc: if null will not attempt to free the buffer. Useful for arena
    /// or stack allocators that do not need to be freed.
    pub fn into_small(this: *This, alloc: ?*const Allocator) !void {
        if (this.isLargeStr()) {
            const len: u64 = this.large.len;
            if (len >= SmallString.buf_size)
                return StringError.TooLargeToConvert;
            var slice = this.large.to_slice();
            var old_cap = this.large.cap;
            this.small.set_length(@intCast(len));
            @memcpy(@as([*]u8, &this.small.data), slice);
            if (alloc) |a| {
                a.free(slice.ptr[0..old_cap]);
            }
        }
    }

    pub fn substr(this: *const This, offset: u64, len: u64, alloc: ?*const Allocator) String {
        const sub: []u8 = this.const_subslice(offset, len);
        if (len <= SmallString.buf_size) {
            return .{ .small = SmallString.init_copy(sub) };
        } else {
            return .{ .large = LargeString.init_copy(sub, 0, alloc) };
        }
    }

    /// returns a subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn subslice(this: *This, offset: u64, len: u64) []u8 {
        return if (this.isSmallStr()) this.small.subslice(offset, len) else this.large.subslice(offset, len);
    }

    /// returns a const subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn const_subslice(this: *const This, offset: u64, len: u64) []const u8 {
        return if (this.isSmallStr()) this.small.const_subslice(offset, len) else this.large.const_subslice(offset, len);
    }

    /// return the string as a slice. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn to_slice(this: *This) []u8 {
        return if (this.isSmallStr()) this.small.to_slice() else this.large.to_slice();
    }

    /// return the string as a const slice. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn to_const_slice(this: *This) []const u8 {
        return if (this.isSmallStr()) this.small.to_const_slice() else this.large.to_const_slice();
    }

    /// returns the length of the string
    pub fn length(this: *const This) u64 {
        return if (this.isSmallStr()) this.small.length() else this.large.len;
    }

    pub fn reserve_more(this: *This, more: u64, alloc: ?*Allocator) !void {
        if (this.isSmallString()) {
            const len = this.small.length() + more;
            if (len > SmallString.buf_size) {
                if (alloc) |a| {
                    var large_str = try LargeString.from_small(this, len * 2, a);
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

    pub fn push_back(this: *This, x: u8, alloc: ?*Allocator) !void {
        try this.reserve_more(@sizeOf(x), alloc);
        if (this.isSmallStr()) this.small.push_back(x) else this.large.push_back_noalloc();
    }

    pub fn append1(this: *This, x: u8, count: u64, alloc: ?*Allocator) !void {
        try this.reserve_more(count, alloc);
        if (this.isSmallString()) this.small.append1(x, count) else this.large.append1_noalloc(x, count);
    }

    /// appends the string to the current string spilling to a LargeString if needed
    /// other: other string to append
    /// alloc: can be left null if you know you will not need to grow the region or
    /// convert to a LargeString
    pub fn append(this: *This, other: *const String, alloc: ?*const Allocator) !void {
        return this.append_slice(other.to_const_slice(), alloc);
    }

    /// appends the slice to the current string spilling to a LargeString if needed
    /// other: other string to append
    /// alloc: can be left null if you know you will not need to grow the region or
    /// convert to a LargeString
    pub fn append_slice(this: *This, other: []const u8, alloc: ?*const Allocator) !void {
        try this.reserve_more(other.len, alloc);
        if (this.isSmallString()) this.small.append(other) else this.large.append_noalloc(other);
    }

    /// sets the length to zero but leaves the rest of the struct for reuse
    pub fn clear(this: *This) void {
        if (this.isSmallStrig()) this.small.clear() else this.large.clear();
    }

    /// ensures at least new_capacity total cap, but will not shribnk the cap.
    /// will spill to large string if needed.
    pub fn reserve(this: *This, new_cap: u64, alloc: ?*const Allocator) !void {
        if (this.isLargeStr()) {
            this.large.reserve(new_cap, alloc);
        } else if (new_cap > SmallString.buf_size) {
            var str = try LargeString.from_small(&this.small, new_cap, alloc);
            this.large = str;
        }
    }

    /// Returns byte at position
    /// index: no check is done in non-safe release modes
    pub fn get1(this: *const This, index: u64) u8 {
        return if (this.isSmallStr()) this.small.get(index) else this.large.get(index);
    }

    /// replaces part of the string with the values from the other string
    /// index: should be less than length, but is not checked in release builds
    pub fn set(this: *This, offset: u64, other: *const String) void {
        return this.set_range(offset, other.to_const_slice());
    }

    /// sets a range of values. no checks are done in release builds
    /// offset: the beginning offset
    /// vals: offset + vals.len should not extend past length but not checked
    /// in release builds
    pub fn set_range(this: *This, offset: u64, vals: []const u8) void {
        if (this.isSmallStr()) this.small.set_range(offset, vals) else this.large.set_range(offset, vals);
    }

    /// sets the index of buffer. no checks are done in releae builds
    /// index: should be less than length, but is not checked in release builds
    pub fn set1(this: *This, index: u64, val: u8) void {
        if (this.isSmallStr()) this.small.set1(index, val) else this.large.set1(index, val);
    }

    /// delete a single characters. will shift all other characters down. deleting
    /// from the end of the string doesn't require any shifting.
    /// index: the character to remove
    pub fn delete1(this: *This, index: u64) void {
        if (this.isSmallStr()) this.small.delete1(index) else this.large.delete1(index);
    }

    /// delete a range of characters. will shift all other characters down. deleting
    /// from the end of the string doesn't require any shifting. This will not cause
    /// any deallocations or convert a large string to a small string.
    /// offset: start of the range to delete. If past length nothing will be deleted
    /// len: how many characters to delete. If this extends the range past len only
    /// characters up to the length of the string will be deleted.
    pub fn delete_range(this: *This, offset: u64, len: u64) void {
        if (this.isSmallStr()) this.small.delete_range(offset, len) else this.large.delete_range(offset, len);
    }
};
