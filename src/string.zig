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
    pub fn init_copy(str: []const u8, alloc: ?*Allocator) !This {
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
    pub fn into_large(this: *This, alloc: *Allocator) !void {
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
    pub fn into_small(this: *This, alloc: ?*Allocator) !void {
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

    /// return the string as a slice
    pub fn to_slice(this: *This) []u8 {
        return if (this.isSmallStr()) this.small.to_slice() else this.large.to_slice();
    }

    /// return the string as a const slice
    pub fn to_const_slice(this: *This) []const u8 {
        return if (this.isSmallStr()) this.small.to_const_slice() else this.large.to_const_slice();
    }

    /// returns the length of the string
    pub fn length(this: *const This) u64 {
        return if (this.isSmallStr()) this.small.length() else this.large.len;
    }

    /// appends the string to the current string spilling to a LargeString if needed
    /// other: other string to append
    /// alloc: can be left null if you know you will not need to grow the region or
    /// convert to a LargeString
    pub fn append(this: *This, other: *const String, alloc: ?*Allocator) !void {
        return this.append_slice(other.to_const_slice(), alloc);
    }

    /// appends the slice to the current string spilling to a LargeString if needed
    /// other: other string to append
    /// alloc: can be left null if you know you will not need to grow the region or
    /// convert to a LargeString
    pub fn append_slice(this: *This, other: []const u8, alloc: ?*Allocator) !void {
        if (this.isSmallString()) {
            const len = this.small.length() + other.len;
            if (len <= SmallString.buf_size) {} else {
                if (alloc) |a| {
                    var large_str = try LargeString.from_small(this, len * 2, a);
                    large_str.append_noalloc(other);
                    this.large = large_str;
                } else {
                    return StringError.NoAllocator;
                }
            }
        } else {
            this.large.append(other, alloc);
        }
    }

    /// sets the length to zero but leaves the rest of the struct for reuse
    pub fn clear(this: *This) void {
        if (this.isSmallStrig()) this.small.clear() else this.large.clear();
    }

    /// ensures at least new_capacity total cap, but will not shribnk the cap.
    /// will spill to large string if needed.
    pub fn reserve(this: *This, new_cap: u64, alloc: *Allocator) !void {
        if (this.isLargeStr()) {
            this.large.reserve(new_cap, alloc);
        } else if (new_cap > SmallString.buf_size) {
            var str = try LargeString.from_small(&this.small, new_cap, alloc);
            this.large = str;
        }
    }
};
