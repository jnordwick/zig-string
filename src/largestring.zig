const std = @import("std");
const Allocator = std.mem.Allocator;

const SmallString = @import("smallstring.zig").SmallString;
const StringError = @import("string.zig").StringError;

// currently this only works on little endian machines. for big
// endian the bit used to distinguish between large and small would
// need to be moved to the high bit of the high byte of cap.

// LargeStrings are always allocated in an even size. The lowest bit
// on the lowest byte is set to 0 to signify this is a LargeString.

pub const LargeString = extern struct {
    cap: u64,
    len: u64,
    data: [*]u8,

    const This = @This();

    fn alloc_data(cap: u64, comptime alloc: Allocator) ![]u8 {
        const request_cap = cap + (cap & 1);
        const data_slice = try alloc.alloc(u8, request_cap);
        std.debug.assert(data_slice.len & 1 == 0);
        return data_slice;
    }

    fn realloc_data(this: *This, new_cap: u64, comptime alloc: Allocator) !void {
        const alloc_slice = this.data[0..this.cap];
        const did_resize = alloc.resize(alloc_slice, new_cap);
        if (did_resize) {
            this.cap = new_cap;
            return;
        }
        const new_data = try alloc_data(new_cap, alloc);
        @memcpy(&new_data, this.to_slice());
        this.deinit(alloc);
        this.cap = new_data.len;
        this.data = new_data.ptr;
    }

    /// create new LargeString.
    /// cap: initial capacity. If cap is odd 1 will be added to keep it even.
    pub fn init(cap: u64, comptime alloc: Allocator) !This {
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
    pub fn init_copy(str: []const u8, cap: u64, comptime alloc: Allocator) !This {
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
    pub fn from_small(str: *const SmallString, cap: u64, comptime alloc: Allocator) !This {
        const str_slice = str.to_const_slice();
        return init_copy(str_slice, cap, alloc);
    }

    /// returns a subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn subslice(this: *This, offset: u64, len: u64) []u8 {
        std.debug.assert(offset < this.len);
        std.debug.assert(offset + len <= this.len);
        return this.data[offset .. offset + len];
    }

    /// returns a const subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn const_subslice(this: *const This, offset: u64, len: u64) []const u8 {
        std.debug.assert(offset < this.len);
        std.debug.assert(offset + len <= this.len);
        return this.data[offset .. offset + len];
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
    pub fn deinit(this: *This, comptime alloc: Allocator) void {
        alloc.free(this.data[0..this.cap]);
    }

    pub fn push_back(this: *This, x: u8, comptime alloc: Allocator) !void {
        const new_len = this.len + @sizeOf(x);
        if (new_len > this.cap) {
            try this.reserve(new_len * 2, alloc);
        }
        this.push_back_noalloc(x);
    }

    pub fn push_back_noalloc(this: *This, x: u8) void {
        this.data[this.len] = x;
        this.len += 1;
    }

    pub fn append1(this: *This, x: u8, count: u64, comptime alloc: Allocator) !void {
        const new_len = this.len + count;
        if (new_len > this.cap) {
            try this.reserve(new_len * 2, alloc);
        }
        this.append1_noalloc(x, count);
    }

    pub fn append1_noalloc(this: *This, x: u8, count: u64) void {
        std.debug.assert(this.len + count <= this.cap);
        const base = this.data + this.len;
        for (0..count) |c| {
            base[c] = x;
        }
        this.len += count;
    }

    /// append a slice to the string, allocating more space if needed
    /// str: a string as a slice, does not need a sentinel terminator
    /// alloc: the allocator used to create the original buffer. see init_copy.
    /// it can be null if you know you will not go past capacity and need more
    /// space. StringError.NoAllocator will be returned if more space is needed
    /// but an allocator isn't supplied.
    pub fn append(this: *This, str: []const u8, comptime alloc: Allocator) !void {
        const new_len = this.len + str.len;
        if (new_len > this.cap) {
            try this.reserve(new_len * 2, alloc);
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
    pub fn reserve(this: *This, new_cap: u64, comptime alloc: Allocator) !void {
        if (new_cap > this.cap) {
            if (alloc) |a| {
                return this.realloc_data(new_cap, a);
            } else {
                return StringError.NoAllocator;
            }
        }
    }

    /// Returns byte at position
    /// index: no check is done in non-safe release modes
    pub fn get1(this: *const This, index: u64) u8 {
        std.debug.assert(index < this.len);
        return this.data[index];
    }

    /// sets the index of buffer. no checks are done in releae builds
    /// index: should be less than length, but is not checked in release builds
    pub fn set1(this: *This, index: u64, val: u8) void {
        std.debug.assert(index < this.len);
        this.data[index] = val;
    }

    /// sets a range of values. no checks are done in release builds
    /// offset: the beginning offset
    /// vals: offset + vals.len should not extend past length but not checked
    /// in release builds
    pub fn set_range(this: *This, offset: u64, vals: []const u8) void {
        std.debug.assert(offset + vals.len < this.len);
        @memcpy(this.data + this.len, vals);
    }

    /// delete a single characters. will shift all other characters down. deleting
    /// from the end of the string doesn't require any shifting.
    /// index: the character to remove
    pub fn delete1(this: *This, index: u64) void {
        const cur_len = this.len;
        if (index >= cur_len)
            return;
        if (index != cur_len - 1) {
            const copy_len = cur_len - index - 1;
            const too_base = this.data + index;
            const too_slice = too_base[0..copy_len];
            const from_base = too_base + 1;
            const from_slice = from_base[0..copy_len];
            std.mem.copyForwards(u8, too_slice, from_slice);
        }
        this.len -= 1;
    }

    /// delete a range of characters. will shift all other characters down. deleting
    /// from the end of the string doesn't require any shifting.
    /// offset: start of the range to delete. If past length nothing will be deleted
    /// len: how many characters to delete. If this extends the range past len only
    /// characters up to the length of the string will be deleted.
    pub fn delete_range(this: *This, offset: u64, len: u64) void {
        const cur_len = this.len;
        if (offset >= cur_len)
            return;
        if (offset + len >= cur_len) {
            this.len = offset;
        } else {
            const copy_len = cur_len - offset - len;
            const too_base = this.data + offset;
            const too_slice = too_base[0..copy_len];
            const from_base = too_base + len;
            const from_slice = from_base[0..copy_len];
            std.mem.copyForwards(u8, too_slice, from_slice);
            this.len -= len;
        }
    }
};
