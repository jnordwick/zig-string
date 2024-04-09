const std = @import("std");

const LargeString = @import("largestring.zig").LargeString;
const StringError = @import("string.zig").StringError;

pub const SmallString = extern struct {
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
    pub fn set_length(this: *This, xlen: u8) void {
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

    pub fn push_back(this: *This, x: u8) void {
        const len = this.length();
        std.debug.assert(len + @sizeOf(x) <= buf_size);
        this.data[len] = x;
        this.set_length(len + @sizeOf(x));
    }

    pub fn append1(this: *This, x: u8, count: u64) void {
        const len = this.length();
        std.debug.assert(len + count <= buf_size);
        const base: [*]u8 = &this.data + this.len;
        for (0..count) |c| {
            base[c] = x;
        }
        this.set_length(len + count);
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

    /// sets the index of buffer. no checks are done in releae builds
    /// index: should be less than length, but is not checked in release builds
    pub fn set(this: *This, index: u64, val: u8) void {
        std.debug.assert(index < this.length());
        this.data[index] = val;
    }

    /// sets a range of values. no checks are done in release builds
    /// offset: the beginning offset
    /// vals: offset + vals.len should not extend past length but not checked
    /// in release builds
    pub fn set_range(this: *This, offset: u64, vals: []u8) void {
        std.debug.assert(offset + vals.len < this.length());
        @memcpy(@as([*]u8, &this.data + offset), vals);
    }

    /// delete a single characters. will shift all other characters down. deleting
    /// from the end of the string doesn't require any shifting.
    /// index: the character to remove
    pub fn delete1(this: *This, index: u64) void {
        const cur_len = this.length();
        if (index >= cur_len)
            return;
        if (index != cur_len - 1) {
            const copy_len = cur_len - index - 1;
            const too_base = @as([*]u8, &this.data) + index;
            const too_slice = too_base[0..copy_len];
            const from_base = too_base + 1;
            const from_slice = from_base[0..copy_len];
            std.mem.copyForwards(u8, too_slice, from_slice);
        }
        this.set_length(cur_len - 1);
    }

    /// delete a range of characters. will shift all other characters down. deleting
    /// from the end of the string doesn't require any shifting.
    /// offset: start of the range to delete. If past length nothing will be deleted
    /// len: how many characters to delete. If this extends the range past len only
    /// characters up to the length of the string will be deleted.
    pub fn delete_range(this: *This, offset: u64, len: u64) void {
        const cur_len = this.length();
        if (offset >= cur_len)
            return;
        if (offset + len >= cur_len) {
            this.set_length(@intCast(offset));
        } else {
            const copy_len = cur_len - offset - len;
            const too_base = @as([*]u8, &this.data) + offset;
            const too_slice = too_base[0..copy_len];
            const from_base = too_base + len;
            const from_slice = from_base[0..copy_len];
            std.mem.copyForwards(u8, too_slice, from_slice);
            this.set_length(@intCast(cur_len - len));
        }
    }
};