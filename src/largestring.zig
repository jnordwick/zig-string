const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const SmallString = @import("smallstring.zig").SmallString;
const StringError = @import("string.zig").StringError;
const low_mask = @import("string.zig").String.low_mask;

comptime {
    if (builtin.target.cpu.arch.endian() == .big)
        @compileError("SSO presently only works in litte endian");
}

/// The LargeString maintains a pointer to an external buffer. The capacity
/// must has at least one bit of String.low_mask u8 set that is used to signal
/// this is a LargeString.
pub const LargeString = LargeStringBase(u64);

pub fn LargeStringBase(Size_: type) type {
    return extern struct {
        const This = @This();
        const Size = Size_;

        cap: Size,
        len: Size,
        data: [*]u8,

        const cap_mask: Size = @intCast(low_mask); // has highest bits set, eg 0b111000...
        const neg_mask: Size = @bitCast(~@as(Size, 0) << @ctz(cap_mask));

        /// allocates a slice with a minimum new_size
        fn alloc_data(new_size: Size, comptime alloc: Allocator) ![]u8 {
            var new_cap = new_size + (new_size >> 1);
            if (new_size & cap_mask == 0) {
                new_cap = (neg_mask & new_cap) | (1 << @ctz(cap_mask));
            }
            const data_slice = try alloc.alloc(u8, new_cap);
            std.debug.assert(data_slice.len & cap_mask != 0);
            return data_slice;
        }

        /// realloc an existing buffer, copying the old portion over
        noinline fn realloc_data(this: *This, new_cap: Size, comptime alloc: Allocator) !void {
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
        pub fn init(cap: Size, comptime alloc: Allocator) !This {
            var this: This = undefined;
            const data_slice = try alloc_data(cap, alloc);
            this.cap = data_slice.len;
            this.len = 0;
            this.data = data_slice.ptr;
            return this;
        }

        /// create new LargeString with initial value. cap is only a suggestion
        pub fn init_copy(str: []const u8, cap: Size, comptime alloc: Allocator) !This {
            std.debug.assert(str.len < std.math.maxInt(Size) - 1);
            var this: This = undefined;
            const slen: Size = @intCast(str.len);
            const alloc_amt: Size = @max(slen, cap);
            const data_slice = try alloc_data(alloc_amt, alloc);
            this.cap = @intCast(data_slice.len);
            this.len = slen;
            this.data = data_slice.ptr;
            @memcpy(this.data, str);
            return this;
        }

        /// convert a small string into a large allocated string
        /// str: the small string to convert
        /// cap: the initial capacity for the allocation. see also init_copy for a description of cap
        pub fn from_small(str: *const SmallString, cap: Size, comptime alloc: Allocator) !This {
            const str_slice = str.to_const_slice();
            return init_copy(str_slice, cap, alloc);
        }

        /// returns a subslice of the string. if the string is ever converted from small to large or has to be
        /// reallocated to a different memory location, this slice will be invaid.
        pub fn subslice(this: *This, offset: Size, len: Size) []u8 {
            std.debug.assert(offset < this.len);
            std.debug.assert(offset + len <= this.len);
            return this.data[offset .. offset + len];
        }

        /// returns a const subslice of the string. if the string is ever converted from small to large or has to be
        /// reallocated to a different memory location, this slice will be invaid.
        pub fn const_subslice(this: *const This, offset: Size, len: Size) []const u8 {
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
            const new_len = this.len + 1;
            if (new_len > this.cap) {
                try this.reserve(new_len, alloc);
            }
            this.data[this.len] = x;
            this.len += 1;
        }

        pub fn append(this: *This, x: u8, count: Size, comptime alloc: Allocator) !void {
            const new_len = this.len + count;
            if (new_len > this.cap) {
                try this.realloc_data(new_len, alloc);
            }
            std.debug.assert(this.len + count <= this.cap);
            const base = this.data + this.len;
            for (0..count) |c| {
                base[c] = x;
            }
            this.len += count;
        }

        /// append a slice to the string, allocating more space if needed.
        pub fn append_slice(this: *This, str: []const u8, comptime alloc: Allocator) !void {
            const new_len = this.len + str.len;
            if (new_len > this.cap) {
                try this.reserve(new_len, alloc);
            }
            std.debug.assert(this.len + str.len <= this.cap);
            @memcpy(&this.data + this.len, str);
            this.len += str.len;
        }

        /// resets the length to zero and keeps capacity. the buffer is not
        /// zeroed so stil has the old data in it.
        pub fn clear(this: *This) void {
            this.length = 0;
        }

        /// Enlarges the buffer to the the new capacity if needed. this will not
        /// shrink the buffer.
        pub fn reserve(this: *This, new_cap: Size, comptime alloc: Allocator) !void {
            if (new_cap > this.cap) {
                return this.realloc_data(new_cap, alloc);
            }
        }

        /// Returns byte at position
        /// index: no check is done in non-safe release modes
        pub fn get(this: *const This, index: Size) u8 {
            std.debug.assert(index < this.len);
            return this.data[index];
        }

        /// sets the index of buffer. no checks are done in releae builds
        /// index: should be less than length, but is not checked in release builds
        pub fn set(this: *This, index: Size, val: u8) void {
            std.debug.assert(index < this.len);
            this.data[index] = val;
        }

        /// sets a range of values. no checks are done in release builds
        /// offset: the beginning offset
        /// vals: offset + vals.len should not extend past length but not checked
        /// in release builds
        pub fn set_range(this: *This, offset: Size, vals: []const u8) void {
            std.debug.assert(offset + vals.len < this.len);
            @memcpy(this.data + this.len, vals);
        }

        /// remove the last char and return it
        pub fn pop(this: *This) u8 {
            this.len -= 1;
            return this.data[this.len];
        }

        /// delete a single characters. will shift all other characters down. deleting
        /// from the end of the string doesn't require any shifting.
        /// index: the character to remove
        pub fn delete(this: *This, index: Size) void {
            const cur_len = this.len;
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

        /// deletes an element by moving the last element into the removed position
        /// and decreasing length by 1;
        pub fn delete_unstable(this: *This, index: Size) void {
            this.len -= 1;
            this.data[index] = this.data[this.len];
        }

        /// delete a range of characters. will shift all other characters down. deleting
        /// from the end of the string doesn't require any shifting.
        /// offset: start of the range to delete. If past length nothing will be deleted
        /// len: how many characters to delete. If this extends the range past len only
        /// characters up to the length of the string will be deleted.
        pub fn delete_range(this: *This, offset: Size, len: Size) void {
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
}
