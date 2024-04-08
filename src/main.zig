const std = @import("std");
const Allocator = std.mem.Allocator;
const Gpa = std.heap.GeneralPurposeAllocator;

// currently this only works on little endian machines. for big
// endian the bit used to distinguish between heap and stack would
// need to be moved to the high bit of the high byte of cap.

// HeapStrings are always allocated in an even size. The lowest bit
// on the lowest byte is set to 0 to signify this is a HeapString.

const HeapString = extern struct {
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
        this.cap = new_data.len;
        this.data = new_data.ptr;
    }

    /// create new HeapString.
    /// cap: initial capacity. If cap is odd 1 will be added to keep it even.
    pub fn init(cap: u64, alloc: *Allocator) !This {
        var this: This = undefined;
        const data_slice = try alloc_data(cap, alloc);
        this.cap = data_slice.len;
        this.len = 0;
        this.data = data_slice.ptr;
        return this;
    }

    /// create new HeapString with initial value
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

    pub fn from_stack(str: *const StackString, cap: u64, alloc: *Allocator) !This {
        const str_slice = str.to_const_slice();
        return init_copy(str_slice, cap, alloc);
    }

    pub fn to_slice(this: *This) []u8 {
        return this.data[0..this.len];
    }

    pub fn to_const_slice(this: *const This) []const u8 {
        return this.data[0..this.len];
    }

    pub fn deinit(this: *This, alloc: *Allocator) void {
        alloc.free(this.data[0..this.cap]);
    }

    pub fn append(this: *This, str: []const u8, alloc: *Allocator) !void {
        const new_len = this.len + str.len;
        if (new_len > this.cap) {
            try this.realloc_data(new_len * 2, alloc);
        }
        this.append_noalloc(str);
    }

    pub fn append_noalloc(this: *This, str: []const u8) void {
        std.debug.assert(this.len + str.len <= this.cap);
        @memcpy(&this.data + this.len, str);
        this.len += str.len;
    }
};

const StackString = extern struct {
    const buf_size = @sizeOf(HeapString) - 1;

    len: u8,
    data: [buf_size]u8,

    const This = @This();

    pub fn init() This {
        return .{ .len = 1, .data = undefined };
    }

    pub fn length(this: *const This) u8 {
        return this.len >> 1;
    }

    fn set_length(this: *This, xlen: u8) void {
        std.debug.assert(xlen <= buf_size);
        this.len = (xlen << 1) | 1;
    }

    pub fn init_copy(str: []const u8) This {
        std.debug.assert(str.len <= buf_size);
        var s: This = undefined;
        s.set_length(@intCast(str.len));
        @memcpy(@as([*]u8, @ptrCast(&s.data)), str);
        return s;
    }

    pub fn to_slice(this: *This) []u8 {
        return this.data[0..this.length()];
    }

    pub fn to_const_slice(this: *const This) []const u8 {
        return this.data[0..this.length()];
    }

    pub fn append(this: *This, str: []const u8) void {
        const len = this.length();
        std.debug.assert(len + str.len <= buf_size);
        @memcpy(&this.data + len, str);
        this.set_length(len + str.len);
    }
};

comptime {
    std.debug.assert(@sizeOf(StackString) == @sizeOf(HeapString));
}

pub const String = extern union {
    lowbyte: u8,
    stack: StackString,
    heap: HeapString,

    const This = @This();

    pub fn isHeapStr(this: This) bool {
        return this.lowbyte & 1 == 0;
    }

    pub fn isStackStr(this: This) bool {
        return this.lowbyte & 1 == 1;
    }

    pub fn init() This {
        return .{ .stack = StackString.init() };
    }

    pub fn init_copy(str: []const u8, alloc: *Allocator) !This {
        if (str.len <= StackString.buf_size) {
            return .{ .stack = StackString.init_copy(str) };
        } else {
            return .{ .heap = try HeapString.init_copy(str, str.len * 2, alloc) };
        }
    }

    pub fn into_heap(this: *This, alloc: *Allocator) !void {
        if (this.isStackStr()) {
            var heap_str = try HeapString.from_stack(&this.stack, 0, alloc);
            this.heap = heap_str;
        }
    }

    pub fn to_slice(this: *This) []u8 {
        return if (this.isStackStr()) this.stack.to_slice() else this.heap.to_slice();
    }

    pub fn to_const_slice(this: *This) []const u8 {
        return if (this.isStackStr()) this.stack.to_const_slice() else this.heap.to_const_slice();
    }

    pub fn length(this: *const This) u64 {
        return if (this.isStackStr()) this.stack.length() else this.heap.len;
    }

    pub fn append(this: *This, other: *const String, alloc: *Allocator) !void {
        return this.append_slice(other.to_const_slice(), alloc);
    }

    pub fn append_slice(this: *This, other: []const u8, alloc: *Allocator) !void {
        if (this.isStackString()) {
            const len = this.stack.length() + other.len;
            if (len <= StackString.buf_size) {
                this.stack.append(other);
            } else {
                var heap_str = try HeapString.from_stack(this, len * 2, alloc);
                heap_str.append_noalloc(other);
                this.heap = heap_str;
            }
        } else {
            this.heap.append(other, alloc);
        }
    }
};

// --- Tests ---

const tt = std.testing;

test "stack copy" {
    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = StackString.init_copy(hs);
    try tt.expectEqual(@as(u8, @intCast(5)), ss.length());
    try tt.expectEqualSlices(u8, hs, ss.to_slice());
}

test "heap copy" {
    var gpa = Gpa(.{}){};
    var alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = try HeapString.init_copy(hs, 100, &alloc);
    defer ss.deinit(&alloc);
    try tt.expectEqualSlices(u8, hs, ss.to_slice());
}

test "stack to heap" {
    var gpa = Gpa(.{}){};
    var alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = StackString.init_copy(hs);

    var heap_str = try HeapString.from_stack(&ss, ss.length() * 2, &alloc);
    defer heap_str.deinit(&alloc);
    try tt.expectEqualSlices(u8, h[0..], heap_str.to_slice());
}

test "union" {
    const str = String.init();
    try tt.expectEqual(@as(u8, 1), str.lowbyte);
    try tt.expect(str.isStackStr());
    try tt.expectEqual(@as(u64, 0), str.length());
}

test "stack into heap" {
    var gpa = Gpa(.{}){};
    var alloc = gpa.allocator();
    defer _ = gpa.deinit();

    const h = "hello";
    var ss = try String.init_copy(h, &alloc);
    try ss.into_heap(&alloc);
    defer ss.heap.deinit(&alloc);

    try tt.expect(ss.isHeapStr());
    try tt.expectEqual(@as(u64, 5), ss.length());
    try tt.expectEqualSlices(u8, h[0..], ss.to_slice());
}
