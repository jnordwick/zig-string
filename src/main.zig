const std = @import("std");
const Allocator = std.mem.Allocator;
const Gpa = std.heap.GeneralPurposeAllocator;

// currently this only works on little endian machines. for big
// endian the bit used to distinguish between large and small would
// need to be moved to the high bit of the high byte of cap.

// LargeStrings are always allocated in an even size. The lowest bit
// on the lowest byte is set to 0 to signify this is a LargeString.

const StringError = error{
    TooLargeToConvert,
    NoAllocator,
} || Allocator.Error;

const LargeString = extern struct {
    cap: u64,
    len: u64,
    data: [*]u8,

    const This = @This();

    fn alloc_data(cap: u64, alloc: *Allocator) ![]u8 {
        const request_cap = cap + (cap & 1);
        const data_slice = try alloc.alloc(u8, request_cap);
        std.debug.assert(data_slice.len & 1 == 0);
        return data_slice;
    }

    fn realloc_data(this: *This, new_cap: u64, alloc: *Allocator) !void {
        const new_data = try alloc_data(new_cap, alloc);
        @memcpy(&new_data, this.to_slice());
        this.deinit(alloc);
        this.cap = new_data.len;
        this.data = new_data.ptr;
    }

    /// create new LargeString.
    /// cap: initial capacity. If cap is odd 1 will be added to keep it even.
    pub fn init(cap: u64, alloc: *Allocator) !This {
        var this: This = undefined;
        const data_slice = try alloc_data(cap, alloc);
        this.cap = data_slice.len;
        this.len = 0;
        this.data = data_slice.ptr;
        return this;
    }

    /// create new LargeString with initial value
    /// str: initial string value
    /// cap: initial capacity. If cap is less tha the string length, the
    /// string length will be used. If cap is odd 1 will be added to keep
    /// it even.
    pub fn init_copy(str: []const u8, cap: u64, alloc: *Allocator) !This {
        var this: This = undefined;
        const alloc_amt = @max(str.len, cap);
        const data_slice = try alloc_data(alloc_amt, alloc);
        this.cap = data_slice.len;
        this.len = str.len;
        this.data = data_slice.ptr;
        @memcpy(this.data, str);
        return this;
    }

    /// convert a small string into a large allocated string
    /// str: the small string to convert
    /// cap: the initial capacity for the allocation. see also init_copy for a description of cap
    pub fn from_small(str: *const SmallString, cap: u64, alloc: *Allocator) !This {
        const str_slice = str.to_const_slice();
        return init_copy(str_slice, cap, alloc);
    }

    /// return the string as a slice
    pub fn to_slice(this: *This) []u8 {
        return this.data[0..this.len];
    }

    /// return the strong as a const slice
    pub fn to_const_slice(this: *const This) []const u8 {
        return this.data[0..this.len];
    }

    /// Free the alloated buffer. This doesn't reset cap or len, and the
    /// object is left in an invalid state. Just init a new one on top
    /// of it to resuse the struct space.
    /// alloc: the allocator used to create the internal buffer. see init_copy
    pub fn deinit(this: *This, alloc: *Allocator) void {
        alloc.free(this.data[0..this.cap]);
    }

    /// append a slice to the string, allocating more space if needed
    /// str: a string as a slice, does not need a sentinel terminator
    /// alloc: the allocator used to create the original buffer. see init_copy.
    /// it can be null if you know you will not go past capacity and need more
    /// space. StringError.NoAllocator will be returned if more space is needed
    /// but an allocator isn't supplied.
    pub fn append(this: *This, str: []const u8, alloc: ?*Allocator) !void {
        const new_len = this.len + str.len;
        if (new_len > this.cap) {
            if (alloc) |a| {
                try this.realloc_data(new_len * 2, a);
            } else {
                return StringError.NoAllocator;
            }
        }
        this.append_noalloc(str);
    }

    /// Append to the buffer. No checks are made for length. The caller is
    /// responsible for making sure it will fit in the buffer.
    pub fn append_noalloc(this: *This, str: []const u8) void {
        std.debug.assert(this.len + str.len <= this.cap);
        @memcpy(&this.data + this.len, str);
        this.len += str.len;
    }

    /// resets the length to zero and keeps capacity. the buffer is not
    /// zeroed so stil has the old data in it.
    pub fn clear(this: *This) void {
        this.length = 0;
    }

    /// enlares the buffer the the new capacity if needed. this will not
    /// shrink the buffer.
    pub fn reserve(this: *This, new_cap: u64, alloc: *Allocator) !void {
        if (new_cap > this.cap) {
            return this.realloc_data(new_cap, alloc);
        }
    }
};

const SmallString = extern struct {
    /// The size of the in situ buffer before it needs to spill
    /// to a LargeString
    pub const buf_size = @sizeOf(LargeString) - 1;

    len: u8,
    data: [buf_size]u8,

    const This = @This();

    pub fn init() This {
        return .{ .len = 1, .data = undefined };
    }

    /// remove the shift from the raw len field and returns
    /// the true length. see set_length.
    pub fn length(this: *const This) u8 {
        return this.len >> 1;
    }

    /// sets the length of the string. The length field is left
    /// shifted by 1 bit and the low bit is set to 1 to signify
    /// this is a small string. The raw len field doesn't contain
    /// the true length because of this.
    fn set_length(this: *This, xlen: u8) void {
        std.debug.assert(xlen <= buf_size);
        this.len = (xlen << 1) | 1;
    }

    /// creates a small string from the supplied slice. no length
    /// checks are done. It is the callers responsibility to ensure it fits.
    pub fn init_copy(str: []const u8) This {
        std.debug.assert(str.len <= buf_size);
        var s: This = undefined;
        s.set_length(@intCast(str.len));
        @memcpy(@as([*]u8, @ptrCast(&s.data)), str);
        return s;
    }

    /// returns the string as a slice
    pub fn to_slice(this: *This) []u8 {
        return this.data[0..this.length()];
    }

    /// returns the strong as a const slice
    pub fn to_const_slice(this: *const This) []const u8 {
        return this.data[0..this.length()];
    }

    /// appends the slice to the in situ buffer. no length checks are done.
    pub fn append(this: *This, str: []const u8) void {
        const len = this.length();
        std.debug.assert(len + str.len <= buf_size);
        @memcpy(&this.data + len, str);
        this.set_length(len + str.len);
    }

    /// sets the length to zero but does not change the buffer.
    pub fn clear(this: *This) void {
        this.set_length(0);
    }
};

comptime {
    std.debug.assert(@sizeOf(SmallString) == @sizeOf(LargeString));
}

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
            @memcpy(&this.small.data, slice);
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

// --- Tests ---

const tt = std.testing;

test "small copy" {
    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = SmallString.init_copy(hs);
    try tt.expectEqual(@as(u8, @intCast(5)), ss.length());
    try tt.expectEqualSlices(u8, hs, ss.to_slice());
}

test "large copy" {
    var gpa = Gpa(.{}){};
    var alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = try LargeString.init_copy(hs, 100, &alloc);
    defer ss.deinit(&alloc);
    try tt.expectEqualSlices(u8, hs, ss.to_slice());
}

test "small to large" {
    var gpa = Gpa(.{}){};
    var alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = SmallString.init_copy(hs);

    var large_str = try LargeString.from_small(&ss, ss.length() * 2, &alloc);
    defer large_str.deinit(&alloc);
    try tt.expectEqualSlices(u8, h[0..], large_str.to_slice());
}

test "union" {
    const str = String.init();
    try tt.expectEqual(@as(u8, 1), str.lowbyte);
    try tt.expect(str.isSmallStr());
    try tt.expectEqual(@as(u64, 0), str.length());
}

test "small into large" {
    var gpa = Gpa(.{}){};
    var alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const h = "hello";
    var ss = try String.init_copy(h, &alloc);
    try ss.into_large(&alloc);
    defer ss.large.deinit(&alloc);

    try tt.expect(ss.isLargeStr());
    try tt.expectEqual(@as(u64, 5), ss.length());
    try tt.expectEqualSlices(u8, h[0..], ss.to_slice());
}

test "large into small" {
    const h = "hello";
    var ss = try String.init_copy(h, &alloc);
    try ss.into_large(&alloc);
    defer ss.large.deinit(&alloc);

    try tt.expect(ss.isLargeStr());
    try tt.expectEqual(@as(u64, 5), ss.length());
    try tt.expectEqualSlices(u8, h[0..], ss.to_slice());
}
