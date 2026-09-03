const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const low_mask = @import("root.zig").String.low_mask;
const SmallString = @import("smallstring.zig").SmallString;
const StringError = @import("root.zig").StringError;

comptime {
    if (builtin.target.cpu.arch.endian() != .little)
        @compileError("SSO presently only works in litte endian");
}

pub const LargeString = extern struct {
    const This = @This();

    cap: usize,
    len: usize,
    buf: [*]u8,

    const cap_mask: usize = @intCast(low_mask);
    const cap_shift = @ctz(cap_mask);

    fn next_legal_cap(cap: usize) usize {
        return cap | if (cap & cap_mask == 0) @as(usize, 1) << cap_shift else 0;
    }

    /// allocates a slice with a minimum new_size
    fn alloc_data(alloc: Allocator, cap_req: usize) ![]u8 {
        const next_cap = next_legal_cap(cap_req + (cap_req >> 1));

        const data_slice = try alloc.alloc(u8, next_cap);
        std.debug.assert(data_slice.len & cap_mask != 0);
        return data_slice;
    }

    /// realloc an existing buffer, copying the old portion over
    noinline fn realloc_data(this: *This, alloc: Allocator, cap_req: usize) !void {
        const next_cap = next_legal_cap(cap_req);
        const alloc_slice = this.buf[0..this.cap];
        const did_resize = alloc.resize(alloc_slice, next_cap);
        if (did_resize) {
            this.cap = next_cap;
            return;
        }
        const new_data = try alloc_data(alloc, next_cap);
        @memcpy(new_data[0..this.len], this.slice());
        this.deinit(alloc);
        this.cap = new_data.len;
        this.buf = new_data.ptr;
    }

    /// create new LargeString.
    pub fn init(alloc: Allocator, cap: usize) !This {
        var this: This = undefined;
        const data_slice = try alloc_data(alloc, cap);
        this.cap = data_slice.len;
        this.len = 0;
        this.buf = data_slice.ptr;
        return this;
    }

    /// create new LargeString with initial value. cap is only a suggestion
    pub fn init_copy(alloc: Allocator, str: []const u8, cap: usize) !This {
        var this: This = undefined;
        const slen: usize = @intCast(str.len);
        const alloc_amt: usize = @max(slen, cap);
        const data_slice = try alloc_data(alloc, alloc_amt);
        this.cap = @intCast(data_slice.len);
        this.len = slen;
        this.buf = data_slice.ptr;
        @memcpy(this.buf, str);
        return this;
    }

    /// convert a small string into a large allocated string
    /// str: the small string to convert
    /// cap: the initial capacity for the allocation. see also init_copy for a description of cap
    pub fn from_small(alloc: Allocator, str: *const SmallString, cap: usize) !This {
        const str_slice = str.const_slice();
        return init_copy(alloc, str_slice, cap);
    }

    /// returns a subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn subslice(this: *This, offset: usize, len: usize) []u8 {
        std.debug.assert(offset < this.len);
        std.debug.assert(offset + len <= this.len);
        return this.buf[offset .. offset + len];
    }

    /// returns a const subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn const_subslice(this: *const This, offset: usize, len: usize) []const u8 {
        std.debug.assert(offset < this.len);
        std.debug.assert(offset + len <= this.len);
        return this.buf[offset .. offset + len];
    }

    /// return the string as a slice
    pub fn slice(this: *This) []u8 {
        return this.buf[0..this.len];
    }

    /// return the strong as a const slice
    pub fn const_slice(this: *const This) []const u8 {
        return this.buf[0..this.len];
    }

    /// Free the alloated buffer. This doesn't reset cap or len, and the
    /// object is left in an invalid state. Just init a new one on top
    /// of it to resuse the struct space.
    /// alloc: the allocator used to create the internal buffer. see init_copy
    pub fn deinit(this: *This, alloc: Allocator) void {
        alloc.free(this.buf[0..this.cap]);
    }

    pub fn push_back(this: *This, alloc: Allocator, x: u8) !void {
        try this.reserve(alloc, this.len + 1);
        this.buf[this.len] = x;
        this.len += 1;
    }

    /// remove the last char and return it
    pub fn pop(this: *This) u8 {
        this.len -= 1;
        return this.buf[this.len];
    }

    pub fn append_char(this: *This, alloc: Allocator, x: u8, count: usize) !void {
        try this.reserve(alloc, this.len + count);
        @memset(this.buf[this.len .. this.len + count], x);
        this.len += count;
    }

    /// append a slice to the string, allocating more space if needed.
    pub fn append_slice(this: *This, alloc: Allocator, str: []const u8) !void {
        try this.reserve(alloc, this.len + str.len);
        @memcpy(this.buf[this.len..][0..str.len], str);
        this.len += str.len;
    }

    /// resets the length to zero and keeps capacity. the buffer is not
    /// zeroed so stil has the old data in it.
    pub fn clear(this: *This) void {
        this.len = 0;
    }

    /// Enlarges the buffer to the the new capacity if needed. this will not
    /// shrink the buffer.
    pub fn reserve(this: *This, alloc: Allocator, new_cap: usize) !void {
        if (new_cap > this.cap) {
            try this.realloc_data(alloc, new_cap);
        }
    }

    /// Returns byte at position
    /// index: no check is done in non-safe release modes
    pub fn get(this: *const This, index: usize) u8 {
        return this.buf[index];
    }

    /// sets the index of buffer. no checks are done in releae builds
    /// index: should be less than length, but is not checked in release builds
    pub fn set(this: *This, index: usize, val: u8) void {
        this.buf[index] = val;
    }

    /// sets a range of values. no checks are done in release builds
    /// offset: the beginning offset
    /// vals: offset + vals.len should not extend past length but not checked
    /// in release builds
    pub fn set_range(this: *This, offset: usize, vals: []const u8) void {
        @memcpy(this.buf[offset..][0..vals.len], vals);
    }

    /// delete a single characters. will shift all other characters down. deleting
    /// from the end of the string doesn't require any shifting.
    /// index: the character to remove
    pub fn delete(this: *This, index: usize) void {
        this.delete_range(index, 1);
    }

    /// deletes an element by moving the last element into the removed position
    /// and decreasing length by 1;
    pub fn delete_unstable(this: *This, index: usize) void {
        if (index < this.len) {
            this.len -= 1;
            this.buf[index] = this.buf[this.len];
        }
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
            this.len = offset;
            return;
        }
        const copy_len = this.len - offset - len;
        const dst = this.buf[offset..][0..copy_len];
        const src = this.buf[offset + len ..][0..copy_len];
        std.mem.copyForwards(u8, dst, src);
        this.len -= len;
    }
};

// testing
fn expectString(s: *const LargeString, expected: []const u8) !void {
    try std.testing.expectEqual(expected.len, s.len);
    try std.testing.expectEqualSlices(u8, expected, s.const_slice());
}

test "LargeString init" {
    var s = try LargeString.init(std.testing.allocator, 32);
    defer s.deinit(std.testing.allocator);

    try std.testing.expect(s.cap >= 32);
    try std.testing.expectEqual(@as(usize, 0), s.len);
    try expectString(&s, "");
}

test "LargeString init_copy" {
    var s = try LargeString.init_copy(
        std.testing.allocator,
        "hello world",
        32,
    );
    defer s.deinit(std.testing.allocator);

    try std.testing.expect(s.cap >= 32);
    try expectString(&s, "hello world");
}

test "LargeString init_copy allocates enough for string" {
    const input = "this is longer than the requested capacity";

    var s = try LargeString.init_copy(
        std.testing.allocator,
        input,
        1,
    );
    defer s.deinit(std.testing.allocator);

    try std.testing.expect(s.cap >= input.len);
    try expectString(&s, input);
}

test "LargeString from_small" {
    var small = SmallString.init_copy("hello world");

    var s = try LargeString.from_small(
        std.testing.allocator,
        &small,
        32,
    );
    defer s.deinit(std.testing.allocator);

    try expectString(&s, "hello world");
}

test "LargeString push_back" {
    var s = try LargeString.init(std.testing.allocator, 1);
    defer s.deinit(std.testing.allocator);

    for ("hello world") |c| {
        try s.push_back(std.testing.allocator, c);
    }

    try expectString(&s, "hello world");
    try std.testing.expect(s.cap >= s.len);
}

test "LargeString push_back reallocates" {
    var s = try LargeString.init(std.testing.allocator, 1);
    defer s.deinit(std.testing.allocator);

    const original_cap = s.cap;

    for ("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz") |c| {
        try s.push_back(std.testing.allocator, c);
    }

    try std.testing.expect(s.cap > original_cap);
    try expectString(&s, "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz");
}

test "LargeString append_char" {
    var s = try LargeString.init(std.testing.allocator, 1);
    defer s.deinit(std.testing.allocator);

    try s.append_char(std.testing.allocator, 'a', 5);
    try expectString(&s, "aaaaa");

    try s.append_char(std.testing.allocator, 'b', 3);
    try expectString(&s, "aaaaabbb");

    try s.append_char(std.testing.allocator, 'x', 0);
    try expectString(&s, "aaaaabbb");
}

test "LargeString append_slice" {
    var s = try LargeString.init(std.testing.allocator, 1);
    defer s.deinit(std.testing.allocator);

    try s.append_slice(std.testing.allocator, "hello");
    try s.append_slice(std.testing.allocator, " ");
    try s.append_slice(std.testing.allocator, "world");

    try expectString(&s, "hello world");
}

test "LargeString reserve" {
    var s = try LargeString.init(std.testing.allocator, 32);
    defer s.deinit(std.testing.allocator);

    const old_cap = s.cap;

    try s.reserve(std.testing.allocator, old_cap + 100);
    try std.testing.expect(s.cap >= old_cap + 100);

    const cap = s.cap;

    // reserve does not shrink.
    try s.reserve(std.testing.allocator, 1);
    try std.testing.expectEqual(cap, s.cap);
}

test "LargeString reserve preserves contents" {
    var s = try LargeString.init_copy(
        std.testing.allocator,
        "preserve me",
        32,
    );
    defer s.deinit(std.testing.allocator);

    try s.reserve(std.testing.allocator, s.cap + 1000);

    try expectString(&s, "preserve me");
}

test "LargeString pop" {
    var s = try LargeString.init_copy(
        std.testing.allocator,
        "abc",
        32,
    );
    defer s.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 'c'), s.pop());
    try std.testing.expectEqual(@as(u8, 'b'), s.pop());
    try std.testing.expectEqual(@as(u8, 'a'), s.pop());
    try std.testing.expectEqual(@as(usize, 0), s.len);
}

test "LargeString clear" {
    var s = try LargeString.init_copy(
        std.testing.allocator,
        "hello world",
        64,
    );
    defer s.deinit(std.testing.allocator);

    const cap = s.cap;

    s.clear();

    try std.testing.expectEqual(@as(usize, 0), s.len);
    try std.testing.expectEqual(cap, s.cap);
    try expectString(&s, "");

    // Verify that the buffer is still usable.
    try s.append_slice(std.testing.allocator, "new contents");
    try expectString(&s, "new contents");
}

test "LargeString get and set" {
    var s = try LargeString.init_copy(
        std.testing.allocator,
        "abcdef",
        32,
    );
    defer s.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 'c'), s.get(2));

    s.set(2, 'X');

    try expectString(&s, "abXdef");
}

test "LargeString set_range" {
    var s = try LargeString.init_copy(
        std.testing.allocator,
        "abcdefghij",
        32,
    );
    defer s.deinit(std.testing.allocator);

    s.set_range(2, "XYZ");
    try expectString(&s, "abXYZfghij");

    // Exact end boundary.
    s.set_range(s.len - 2, "12");
    try expectString(&s, "abXYZfgh12");

    // Empty range.
    s.set_range(s.len, "");
    try expectString(&s, "abXYZfgh12");
}

test "LargeString subslice" {
    var s = try LargeString.init_copy(
        std.testing.allocator,
        "abcdefghij",
        32,
    );
    defer s.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("cde", s.subslice(2, 3));
    try std.testing.expectEqualStrings("abc", s.subslice(0, 3));
    try std.testing.expectEqualStrings("hij", s.subslice(7, 3));
    try std.testing.expectEqualStrings("abcdefghij", s.subslice(0, s.len));
}

test "LargeString const_subslice" {
    var s = try LargeString.init_copy(
        std.testing.allocator,
        "abcdefghij",
        32,
    );
    defer s.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("cde", s.const_subslice(2, 3));
    try std.testing.expectEqualStrings("abcdefghij", s.const_subslice(0, s.len));
}

test "LargeString delete" {
    var s = try LargeString.init_copy(
        std.testing.allocator,
        "abcde",
        32,
    );
    defer s.deinit(std.testing.allocator);

    s.delete(2);
    try expectString(&s, "abde");

    s.delete(0);
    try expectString(&s, "bde");

    s.delete(s.len - 1);
    try expectString(&s, "bd");

    // Out of range is a no-op.
    s.delete(100);
    try expectString(&s, "bd");
}

test "LargeString delete_range" {
    var s = try LargeString.init_copy(
        std.testing.allocator,
        "abcdefghij",
        32,
    );
    defer s.deinit(std.testing.allocator);

    // Middle.
    s.delete_range(3, 2);
    try expectString(&s, "abcfghij");

    // Beginning.
    s.delete_range(0, 2);
    try expectString(&s, "cfghij");

    // End.
    s.delete_range(4, 2);
    try expectString(&s, "cfgh");

    // Extends beyond end.
    s.delete_range(2, 100);
    try expectString(&s, "cf");

    // Starts outside string.
    s.delete_range(100, 5);
    try expectString(&s, "cf");

    // Zero length.
    s.delete_range(1, 0);
    try expectString(&s, "cf");
}

test "LargeString delete_unstable" {
    var s = try LargeString.init_copy(
        std.testing.allocator,
        "abcde",
        32,
    );
    defer s.deinit(std.testing.allocator);

    s.delete_unstable(1);
    try expectString(&s, "aecd");

    s.delete_unstable(0);
    try expectString(&s, "dec");

    s.delete_unstable(s.len - 1);
    try expectString(&s, "de");
}

test "LargeString capacity invariant" {
    var s = try LargeString.init(std.testing.allocator, 0);
    defer s.deinit(std.testing.allocator);

    try std.testing.expect(s.cap & LargeString.cap_mask != 0);

    for (0..1024) |n| {
        try s.reserve(std.testing.allocator, n);
        try std.testing.expect(s.cap >= n);
        try std.testing.expect(s.cap & LargeString.cap_mask != 0);
    }
}
