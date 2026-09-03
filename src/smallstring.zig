const std = @import("std");

const LargeString = @import("largestring.zig").LargeString;
const StringError = @import("root.zig").StringError;

pub const SmallString = extern struct {
    const This = @This();
    /// The size of the in situ buffer before it needs to spill to a LargeString
    pub const buf_size = @sizeOf(LargeString) - 1;

    len: u8,
    buf: [buf_size]u8,

    pub fn init() This {
        return .{ .len = 0, .buf = undefined };
    }

    /// creates a small string from the supplied slice. no length
    /// checks are done. It is the callers responsibility to ensure it fits.
    pub fn init_copy(str: []const u8) This {
        std.debug.assert(str.len <= buf_size);
        var s = This{ .len = @intCast(str.len), .buf = undefined };
        @memcpy(@as([*]u8, @ptrCast(&s.buf)), str);
        return s;
    }

    /// returns a subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn subslice(this: *This, offset: usize, len: usize) []u8 {
        std.debug.assert(offset + len <= this.len);
        return this.buf[offset .. offset + len];
    }

    /// returns a const subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn const_subslice(this: *const This, offset: usize, len: usize) []const u8 {
        std.debug.assert(offset + len <= this.len);
        return this.buf[offset .. offset + len];
    }

    /// returns the string as a slice
    pub fn slice(this: *This) []u8 {
        return this.buf[0..this.len];
    }

    /// returns the strong as a const slice
    pub fn const_slice(this: *const This) []const u8 {
        return this.buf[0..this.len];
    }

    /// append char to buffer
    pub fn push_back(this: *This, x: u8) void {
        std.debug.assert(this.len < buf_size);
        this.buf[this.len] = x;
        this.len += 1;
    }

    /// remove last char from buffer. returns null on empty string
    pub fn pop(this: *This) ?u8 {
        if (this.len == 0) return null;
        this.len -= 1;
        return this.buf[this.len];
    }

    pub fn append_char(this: *This, x: u8, count: usize) void {
        std.debug.assert(this.len + count <= buf_size);
        @memset(this.buf[this.len .. this.len + count], x);
        this.len += @intCast(count);
    }

    /// appends the slice to the in situ buffer. no length checks are done.
    pub fn append_slice(this: *This, str: []const u8) void {
        std.debug.assert(this.len + str.len <= buf_size);
        @memcpy(this.buf[this.len..][0..str.len], str);
        this.len += @intCast(str.len);
    }

    /// sets the length to zero but does not change the buffer.
    pub fn clear(this: *This) void {
        this.len = 0;
    }

    /// Returns byte at position
    /// index: no check is done in non-safe release modes
    pub fn get(this: *const This, index: usize) u8 {
        return this.buf[index];
    }

    /// sets the index of buffer. no checks are done in releae builds
    pub fn set(this: *This, index: usize, x: u8) void {
        this.buf[index] = x;
    }

    /// sets a range of values. no checks are done in release builds
    /// offset: the beginning offset
    pub fn set_range(this: *This, offset: usize, vals: []const u8) void {
        std.debug.assert(offset + vals.len <= this.len);
        @memcpy(this.buf[offset..][0..vals.len], vals);
    }

    /// delete a single characters. will shift all other characters down. deleting
    /// from the end of the string doesn't require any shifting.
    /// index: the character to remove
    pub fn delete(this: *This, index: usize) void {
        const cur_len = this.len;
        if (index >= cur_len) return;
        if (index != cur_len - 1) {
            const copy_len = cur_len - index - 1;
            const too_base = @as([*]u8, &this.buf) + index;
            const too_slice = too_base[0..copy_len];
            const from_base = too_base + 1;
            const from_slice = from_base[0..copy_len];
            std.mem.copyForwards(u8, too_slice, from_slice);
        }
        this.len = cur_len - 1;
    }

    pub fn delete_unstable(this: *This, index: usize) void {
        this.len -= 1;
        this.buf[index] = this.buf[this.len];
    }

    /// delete a range of characters. will shift all other characters down. deleting
    /// from the end of the string doesn't require any shifting.
    /// offset: start of the range to delete. If past length nothing will be deleted
    /// len: how many characters to delete. If this extends the range past len only
    /// characters up to the length of the string will be deleted.
    pub fn delete_range(this: *This, offset: usize, len: usize) void {
        if (offset >= this.len or len == 0)
            return;
        if (offset + len >= this.len) {
            this.len = @intCast(offset);
            return;
        }
        const copy_len = this.len - offset - len;
        const dst = this.buf[offset..][0..copy_len];
        const src = this.buf[offset + len ..][0..copy_len];
        std.mem.copyForwards(u8, dst, src);
        this.len = @intCast(this.len - len);
    }
};

test "set_range can modify through end of string" {
    var s = SmallString.init_copy("hello");

    s.set_range(2, "llo");

    try std.testing.expectEqualStrings("hello", s.const_slice());
}

test "SmallString boundaries" {
    var s = SmallString.init();

    try std.testing.expectEqual(@as(usize, 0), s.len);
    try std.testing.expectEqualStrings("", s.const_slice());

    // Fill exactly to capacity.
    for (0..SmallString.buf_size) |i| {
        s.push_back(@intCast('a' + i % 26));
    }

    try std.testing.expectEqual(SmallString.buf_size, s.len);

    // Pop back to empty.
    var i: usize = SmallString.buf_size;
    while (i != 0) {
        i -= 1;
        try std.testing.expectEqual(@as(u8, @intCast('a' + i % 26)), s.pop().?);
    }

    try std.testing.expectEqual(@as(usize, 0), s.len);
    try std.testing.expect(s.pop() == null);
}

test "append_char boundaries" {
    var s = SmallString.init();

    s.append_char('x', SmallString.buf_size);
    try std.testing.expectEqual(SmallString.buf_size, s.len);
    try std.testing.expectEqualStrings(
        &[_]u8{'x'} ** SmallString.buf_size,
        s.const_slice(),
    );

    // Zero append at capacity is valid.
    s.append_char('y', 0);
    try std.testing.expectEqual(SmallString.buf_size, s.len);
}

test "append_slice exact capacity" {
    var s = SmallString.init();

    const a = "abcdefghijkl";
    const b = "mnopqrstuvw";

    s.append_slice(a);
    s.append_slice(b);

    try std.testing.expectEqual(SmallString.buf_size, s.len);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvw", s.const_slice());
}

test "pop" {
    var s = SmallString.init_copy("abc");

    try std.testing.expectEqual(@as(u8, 'c'), s.pop().?);
    try std.testing.expectEqualStrings("ab", s.const_slice());

    try std.testing.expectEqual(@as(u8, 'b'), s.pop().?);
    try std.testing.expectEqual(@as(u8, 'a'), s.pop().?);
    try std.testing.expect(s.pop() == null);
}

test "delete" {
    var s = SmallString.init_copy("abcde");

    s.delete(0);
    try std.testing.expectEqualStrings("bcde", s.const_slice());

    s.delete(1);
    try std.testing.expectEqualStrings("bde", s.const_slice());

    s.delete(s.len - 1);
    try std.testing.expectEqualStrings("bd", s.const_slice());

    // Out of range is explicitly a no-op.
    s.delete(100);
    try std.testing.expectEqualStrings("bd", s.const_slice());
}

test "delete_range" {
    var s = SmallString.init_copy("abcdefghij");

    s.delete_range(3, 2);
    try std.testing.expectEqualStrings("abcfghij", s.const_slice());

    s.delete_range(0, 2);
    try std.testing.expectEqualStrings("cfghij", s.const_slice());

    s.delete_range(4, 2);
    try std.testing.expectEqualStrings("cfgh", s.const_slice());

    // Extends past end: truncate at offset.
    s.delete_range(2, 100);
    try std.testing.expectEqualStrings("cf", s.const_slice());

    // Past end: no-op.
    s.delete_range(100, 5);
    try std.testing.expectEqualStrings("cf", s.const_slice());

    // Zero length: no-op.
    s.delete_range(1, 0);
    try std.testing.expectEqualStrings("cf", s.const_slice());
}

test "delete_unstable" {
    var s = SmallString.init_copy("abcde");

    s.delete_unstable(1);
    try std.testing.expectEqualStrings("aecd", s.const_slice());
}
