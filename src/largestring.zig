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
