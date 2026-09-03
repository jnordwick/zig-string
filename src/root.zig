const std = @import("std");
const Allocator = std.mem.Allocator;

const LargeString = @import("largestring.zig").LargeString;
const SmallString = @import("smallstring.zig").SmallString;

pub const TransformFunc = fn (char: u8) u8;

pub const StringError = error{
    TooLargeToConvert,
    NoAllocator,
} || Allocator.Error;

/// A string with short string optimization. It can store up to 23 bytes in
/// situ before it spill to an external allocation. While in short string mode
/// no allocations are done.  No checks are done anywhere yet.
pub const String = extern union {
    const This = @This();

    /// Hash context that uses a simpler FNV-1ar for small strings. Subject to change
    /// to something more ASCII specific given the low entropy in short text strings.
    pub const Hasher32 = This.HashContext(u32, std.hash.Fnv1a_32);
    pub const Hasher64 = This.HashContext(u64, std.hash.Fnv1a_64);

    pub fn HashContext(Return: type, Hasher: type) type {
        return struct {
            pub fn hash(_: @This(), s: *const This) Return {
                var hh: Hasher = .init();
                hh.update(s.const_slice());
                return hh.final();
            }
            pub fn eql(_: @This(), x: *const This, y: *const This) bool {
                return x.eql(y);
            }
        };
    }

    pub const low_mask: u8 = 0b11100000;

    /// the top 3 bits are alawys zero for a small string
    /// any bit set is a large string
    lowbyte: u8,
    small: SmallString,
    large: LargeString,

    pub fn is_small(this: *const This) bool {
        return this.lowbyte & low_mask == 0;
    }

    /// create a new zero length string as a SmallString
    pub fn init() This {
        return .{ .small = SmallString.init() };
    }

    /// create a new string from a slice
    pub fn init_copy(alloc: Allocator, str: []const u8) !This {
        std.debug.assert(str.len < std.math.maxInt(usize) - 1);
        const slen: usize = @intCast(str.len);
        if (slen <= SmallString.buf_size) {
            return .{ .small = SmallString.init_copy(str) };
        } else {
            return .{ .large = try LargeString.init_copy(alloc, str, slen * 2) };
        }
    }

    pub fn deinit(this: *This, alloc: Allocator) void {
        if (!this.is_small()) this.large.deinit(alloc);
    }

    /// If not already a LargeString, will convert this to one with the
    /// same capacity as the string length.
    pub fn into_large(this: *This, alloc: Allocator) !void {
        if (this.is_small()) {
            const large_str = try LargeString.from_small(alloc, &this.small, 0);
            this.large = large_str;
        }
    }

    /// If not already a SmallString will convert the LargeString and
    /// free its buffer if requested. If the string is too long to fit
    /// in a small string StringError.TooLargeToConvert will be returned.
    pub fn into_small(this: *This, alloc: Allocator) !void {
        if (!this.is_small()) {
            const len: usize = this.large.len;
            if (len > SmallString.buf_size)
                return StringError.TooLargeToConvert;
            var sl = this.large.slice();
            const old_cap = this.large.cap;

            this.small.len = @intCast(len);
            @memcpy(this.small.buf[0..len], sl);
            alloc.free(sl.ptr[0..old_cap]);
        }
    }

    pub fn substr(this: *const This, alloc: Allocator, offset: usize, len: usize) StringError!String {
        const sub: []const u8 = this.const_subslice(offset, len);
        if (len <= SmallString.buf_size) {
            return .{ .small = SmallString.init_copy(sub) };
        } else {
            return .{ .large = try LargeString.init_copy(alloc, sub, 0) };
        }
    }

    /// returns a subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn subslice(this: *This, offset: usize, len: usize) []u8 {
        return if (this.is_small()) this.small.subslice(offset, len) else this.large.subslice(offset, len);
    }

    /// returns a const subslice of the string. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn const_subslice(this: *const This, offset: usize, len: usize) []const u8 {
        return if (this.is_small()) this.small.const_subslice(offset, len) else this.large.const_subslice(offset, len);
    }

    /// return the string as a slice. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn slice(this: *This) []u8 {
        return if (this.is_small()) this.small.slice() else this.large.slice();
    }

    /// return the string as a const slice. if the string is ever converted from small to large or has to be
    /// reallocated to a different memory location, this slice will be invaid.
    pub fn const_slice(this: *const This) []const u8 {
        return if (this.is_small()) this.small.const_slice() else this.large.const_slice();
    }

    /// returns the length of the string
    pub fn length(this: *const This) usize {
        return if (this.is_small()) this.small.len else this.large.len;
    }

    pub fn reserve_more(this: *This, alloc: Allocator, more: usize) !void {
        if (this.is_small()) {
            const len = this.small.len + more;
            if (len > SmallString.buf_size) {
                const large_str = try LargeString.from_small(alloc, &this.small, (len + (len >> 1)));
                this.large = large_str;
            }
        } else {
            const len = this.large.len + more;
            if (len > this.large.cap) {
                try this.large.reserve(alloc, len * 2);
            }
        }
    }

    /// a simple method ao append a char
    pub fn push_back(this: *This, alloc: Allocator, x: u8) !void {
        return this.append_char(alloc, x, 1);
    }

    /// append count of char x
    pub fn append_char(this: *This, alloc: Allocator, x: u8, count: usize) !void {
        try this.reserve_more(alloc, count);
        if (this.is_small()) {
            this.small.append_char(x, count);
        } else {
            try this.large.append_char(alloc, x, count);
        }
    }

    /// appends the string to the current string
    pub fn append(this: *This, alloc: Allocator, other: *const String) !void {
        return this.append_slice(alloc, other.const_slice());
    }

    /// appends the slice to the current string spilling to a LargeString if needed
    pub fn append_slice(this: *This, alloc: Allocator, other: []const u8) !void {
        try this.reserve_more(alloc, other.len);
        if (this.is_small()) {
            this.small.append_slice(other);
        } else {
            try this.large.append_slice(alloc, other);
        }
    }

    /// sets the length to zero but leaves the rest of the struct for reuse
    pub fn clear(this: *This) void {
        if (this.is_small()) this.small.clear() else this.large.clear();
    }

    /// ensures at least new_capacity total cap, but will not shribnk the cap.
    /// will spill to large string if needed.
    pub fn reserve(this: *This, alloc: Allocator, req_cap: usize) !void {
        if (!this.is_small()) {
            try this.large.reserve(alloc, req_cap);
        } else if (req_cap > SmallString.buf_size) {
            const str = try LargeString.from_small(alloc, &this.small, req_cap);
            this.large = str;
        }
    }

    /// Returns byte at position
    pub fn get_char(this: *const This, index: usize) u8 {
        return if (this.is_small()) this.small.get(index) else this.large.get(index);
    }

    /// replaces part of the string with the values from the other string
    pub fn set(this: *This, offset: usize, other: *const String) void {
        return this.set_range(offset, other.const_slice());
    }

    /// sets a range of values starting at offset in string
    pub fn set_range(this: *This, offset: usize, vals: []const u8) void {
        if (this.is_small()) this.small.set_range(offset, vals) else this.large.set_range(offset, vals);
    }

    /// sets the index of buffer
    pub fn set_char(this: *This, index: usize, val: u8) void {
        if (this.is_small()) this.small.set(index, val) else this.large.set(index, val);
    }

    pub fn pop(this: *This) ?u8 {
        return if (this.is_small()) this.small.pop() else this.large.pop();
    }

    /// delete a single characters. will shift all other characters down. deleting
    /// from the end of the string doesn't require any shifting.
    pub fn delete(this: *This, index: usize) void {
        if (this.is_small()) this.small.delete(index) else this.large.delete(index);
    }

    /// deletes a character by moving the last character to the deleted location.
    pub fn delete_unstable(this: *This, index: usize) void {
        if (this.is_small()) this.small.delete_unstable(index) else this.largs.delete_unstable(index);
    }

    /// delete a range of characters. will shift all other characters down. deleting
    /// from the end of the string doesn
    /// any deallocations or convert a large string to a small string.
    pub fn delete_range(this: *This, offset: usize, len: usize) void {
        if (this.is_small()) this.small.delete_range(offset, len) else this.large.delete_range(offset, len);
    }

    pub fn format(this: This, writer: *std.Io.Writer) !void {
        try writer.print("{s}", .{this.const_slice()});
    }

    pub fn eql(this: *const String, that: *const String) bool {
        return std.mem.eql(u8, this.const_slice(), that.const_slice());
    }

    pub fn ieql(this: *const String, that: *const String, tr: TransformFunc) bool {
        const xsl = this.const_slice();
        const ysl = that.const_slice();

        if (xsl.len != ysl.len) return false;
        for (xsl, ysl) |x, y| {
            if (tr(x) != tr(y))
                return false;
        }
        return true;
    }

    pub fn transform(this: *String, tr: TransformFunc) void {
        var sl = this.slice();
        for (0..sl.len) |i| {
            sl[i] = tr(sl[i]);
        }
    }
};

const testing = std.testing;

test "init" {
    var s = String.init();

    try testing.expect(s.is_small());
    try testing.expectEqualStrings("", s.const_slice());
}

test "init_copy small strings" {
    const cases = [_][]const u8{
        "",
        "a",
        "hello",
        "1234567890123456789012", // 22
        "12345678901234567890123", // 23
    };

    for (cases) |expected| {
        var s = try String.init_copy(testing.allocator, expected);
        defer s.deinit(testing.allocator);

        try testing.expect(s.is_small());
        try testing.expectEqualStrings(expected, s.const_slice());
    }
}

test "init_copy spills at 24 bytes" {
    const expected = "123456789012345678901234";

    var s = try String.init_copy(testing.allocator, expected);
    defer s.deinit(testing.allocator);

    try testing.expect(!s.is_small());
    try testing.expect(s.large.cap >= expected.len);
    try testing.expectEqualStrings(expected, s.const_slice());
}

test "push_back across SSO boundary" {
    const input = "123456789012345678901234";
    var s = String.init();
    defer s.deinit(testing.allocator);

    for (input) |c| {
        try s.push_back(testing.allocator, c);
    }

    try testing.expect(!s.is_small());
    try testing.expectEqualStrings(input, s.const_slice());

    // Verify the spill didn't corrupt anything already present.
    try s.push_back(testing.allocator, 'X');
    try testing.expectEqualStrings(input ++ "X", s.const_slice());
}

test "append_char across SSO boundary" {
    const input = "xxxxxxxxxxxxxxxxxxxxxx";
    var s = String.init();
    defer s.deinit(testing.allocator);

    try s.append_char(testing.allocator, 'x', 23);
    try testing.expect(s.is_small());
    try testing.expectEqualStrings(input ++ "x", s.const_slice());

    try s.append_char(testing.allocator, 'y', 1);
    try testing.expect(!s.is_small());
    try testing.expectEqualStrings(input ++ "xy", s.const_slice());
}

test "append small to small" {
    var s = try String.init_copy(testing.allocator, "hello");
    defer if (!s.is_small()) s.large.deinit(testing.allocator);
    var other = try String.init_copy(testing.allocator, " world");
    defer if (!other.is_small()) other.large.deinit(testing.allocator);

    try s.append(testing.allocator, &other);
    try testing.expect(s.is_small());
    try testing.expectEqualStrings("hello world", s.const_slice());
}

test "append causing spill" {
    const n1 = "123456789012345678";
    const n2 = "90123456";
    var s = try String.init_copy(testing.allocator, n1);
    defer if (!s.is_small()) s.large.deinit(testing.allocator);
    var other = try String.init_copy(testing.allocator, n2);
    defer if (!other.is_small()) other.large.deinit(testing.allocator);

    try s.append(testing.allocator, &other);
    try testing.expect(!s.is_small());
    try testing.expectEqualStrings(n1 ++ n2, s.const_slice());
}

test "append large to large" {
    const aaa = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const bbb = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    var s = try String.init_copy(testing.allocator, aaa);
    defer s.deinit(testing.allocator);
    var other = try String.init_copy(testing.allocator, bbb);
    defer other.deinit(testing.allocator);

    try s.append(testing.allocator, &other);
    try testing.expect(!s.is_small());
    try testing.expectEqualStrings(aaa ++ bbb, s.const_slice());
}

test "reserve crosses SSO boundary" {
    var s = String.init();
    defer s.deinit(testing.allocator);
    try s.append_slice(testing.allocator, "hello");
    try s.reserve(testing.allocator, 100);

    try testing.expect(!s.is_small());
    try testing.expect(s.large.cap >= 100);
    try testing.expectEqualStrings("hello", s.const_slice());
}

test "reserve does not shrink" {
    const input = "123456789012345678901234";
    var s = try String.init_copy(
        testing.allocator,
        input,
    );
    defer s.large.deinit(testing.allocator);
    const old_cap = s.large.cap;

    try s.reserve(testing.allocator, old_cap / 2);
    try testing.expectEqual(old_cap, s.large.cap);
    try testing.expectEqualStrings(input, s.const_slice());
}

test "into_large" {
    var s = try String.init_copy(testing.allocator, "hello");
    defer s.large.deinit(testing.allocator);

    try testing.expect(s.is_small());
    try s.into_large(testing.allocator);
    try testing.expect(!s.is_small());
    try testing.expect(s.large.cap >= s.length());
    try testing.expectEqualStrings("hello", s.const_slice());
}

test "into_large is no-op for large string" {
    var s = try String.init_copy(
        testing.allocator,
        "123456789012345678901234",
    );
    defer s.deinit(testing.allocator);

    const old_ptr = s.large.buf;
    const old_cap = s.large.cap;
    try s.into_large(testing.allocator);
    try testing.expect(!s.is_small());
    try testing.expectEqual(old_ptr, s.large.buf);
    try testing.expectEqual(old_cap, s.large.cap);
}

test "into_small converts large string" {
    const a = "123456789012345678901234";
    var s = try String.init_copy(std.testing.allocator, a);
    defer s.deinit(std.testing.allocator);

    try testing.expectEqual(@as(usize, 24), s.length());
    try testing.expect(!s.is_small());
    _ = s.pop();
    try testing.expectEqual(@as(usize, 23), s.length());
    try s.into_small(testing.allocator);
    try testing.expect(s.is_small());
    try testing.expectEqualStrings("12345678901234567890123", s.const_slice());
}

test "into_small rejects strings larger than SSO" {
    var s = try String.init_copy(
        testing.allocator,
        "123456789012345678901234",
    );
    defer s.deinit(testing.allocator);

    const result = s.into_small(testing.allocator);
    try testing.expectError(StringError.TooLargeToConvert, result);
    try testing.expect(!s.is_small());
    try testing.expectEqualStrings("123456789012345678901234", s.const_slice());
}

test "get and set character" {
    var s = try String.init_copy(testing.allocator, "hello");
    defer s.deinit(testing.allocator);

    try testing.expectEqual('h', s.get_char(0));
    try testing.expectEqual('o', s.get_char(4));

    s.set_char(1, 'a');

    try testing.expectEqualStrings("hallo", s.const_slice());
}

test "set_range" {
    var s = try String.init_copy(testing.allocator, "hello world");
    defer s.deinit(testing.allocator);

    s.set_range(6, "there");

    try testing.expectEqualStrings("hello there", s.const_slice());
}

test "set using String" {
    var s = try String.init_copy(testing.allocator, "hello world");
    defer s.deinit(testing.allocator);

    var other = try String.init_copy(testing.allocator, "there");
    defer other.deinit(testing.allocator);

    s.set(6, &other);

    try testing.expectEqualStrings("hello there", s.const_slice());
}

test "pop" {
    var s = try String.init_copy(testing.allocator, "hello");
    defer s.deinit(testing.allocator);

    try testing.expectEqual('o', s.pop());
    try testing.expectEqualStrings("hell", s.const_slice());

    try testing.expectEqual('l', s.pop());
    try testing.expectEqualStrings("hel", s.const_slice());
}

test "delete" {
    var s = try String.init_copy(testing.allocator, "abcdef");
    defer s.deinit(testing.allocator);

    s.delete(2);
    try testing.expectEqualStrings("abdef", s.const_slice());
    s.delete(0);
    try testing.expectEqualStrings("bdef", s.const_slice());
    s.delete(3);
    try testing.expectEqualStrings("bde", s.const_slice());
}

test "delete out of range is no-op" {
    var s = try String.init_copy(testing.allocator, "hello");
    defer s.deinit(testing.allocator);

    s.delete(100);
    try testing.expectEqualStrings("hello", s.const_slice());
}

test "delete_range" {
    var s = try String.init_copy(testing.allocator, "abcdefghij");
    defer s.deinit(testing.allocator);

    s.delete_range(2, 3);

    try testing.expectEqualStrings("abfghij", s.const_slice());
}

test "delete_range to end" {
    var s = try String.init_copy(testing.allocator, "abcdefghij");
    defer s.deinit(testing.allocator);

    s.delete_range(6, 100);

    try testing.expectEqualStrings("abcdef", s.const_slice());
}

test "delete_range zero length" {
    var s = try String.init_copy(testing.allocator, "abcdefghij");
    defer s.deinit(testing.allocator);

    s.delete_range(4, 0);

    try testing.expectEqualStrings("abcdefghij", s.const_slice());
}

test "delete_range past end is no-op" {
    var s = try String.init_copy(testing.allocator, "abcdefghij");
    defer s.deinit(testing.allocator);

    s.delete_range(100, 5);

    try testing.expectEqualStrings("abcdefghij", s.const_slice());
}

test "delete_range does not convert large to small" {
    var s = try String.init_copy(
        testing.allocator,
        "123456789012345678901234",
    );
    defer s.deinit(testing.allocator);

    s.delete_range(5, 100);

    try testing.expect(!s.is_small());
    try testing.expectEqualStrings("12345", s.const_slice());
}

test "subslice" {
    var s = try String.init_copy(testing.allocator, "hello world");
    defer s.deinit(testing.allocator);

    try testing.expectEqualStrings("world", s.const_subslice(6, 5));
}

test "substr creates independent string" {
    var s = try String.init_copy(testing.allocator, "hello world");
    defer s.deinit(testing.allocator);

    var sub = try s.substr(testing.allocator, 6, 5);
    defer sub.deinit(testing.allocator);

    try testing.expectEqualStrings("world", sub.const_slice());

    s.set_char(6, 'W');

    try testing.expectEqualStrings("hello World", s.const_slice());
    try testing.expectEqualStrings("world", sub.const_slice());
}

test "eql" {
    var a = try String.init_copy(testing.allocator, "hello");
    defer a.deinit(testing.allocator);

    var b = try String.init_copy(testing.allocator, "hello");
    defer b.deinit(testing.allocator);

    var c = try String.init_copy(testing.allocator, "Hello");
    defer c.deinit(testing.allocator);

    try testing.expect(a.eql(&b));
    try testing.expect(!a.eql(&c));
}

test "eql across representations" {
    var small = try String.init_copy(
        testing.allocator,
        "12345678901234567890123",
    );
    defer small.deinit(testing.allocator);

    var large = try String.init_copy(
        testing.allocator,
        "12345678901234567890123",
    );
    defer large.deinit(testing.allocator);

    try large.into_large(testing.allocator);

    try testing.expect(small.is_small());
    try testing.expect(!large.is_small());
    try testing.expect(small.eql(&large));
    try testing.expect(large.eql(&small));
}

test "transform" {
    var s = try String.init_copy(testing.allocator, "Hello World");
    defer s.deinit(testing.allocator);

    s.transform(std.ascii.toLower);

    try testing.expectEqualStrings("hello world", s.const_slice());
}

test "format" {
    var s = try String.init_copy(testing.allocator, "hello");
    defer s.deinit(testing.allocator);

    const formatted = try std.fmt.allocPrint(
        testing.allocator,
        "{f} {}",
        .{ s, 42 },
    );
    defer testing.allocator.free(formatted);
    try testing.expectEqualStrings("hello 42", formatted);
}

test "hash equality" {
    var a = try String.init_copy(testing.allocator, "hello");
    defer a.deinit(testing.allocator);

    var b = try String.init_copy(testing.allocator, "hello");
    defer b.deinit(testing.allocator);

    const h32 = String.Hasher32{};
    const h64 = String.Hasher64{};

    try testing.expectEqual(h32.hash(&a), h32.hash(&b));
    try testing.expectEqual(h64.hash(&a), h64.hash(&b));
}
