const std = @import("std");
const Allocator = std.mem.Allocator;

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
