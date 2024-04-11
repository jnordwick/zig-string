const std = @import("std");
const builtin = @import("builtin");

const bstr = @import("string.zig");
const sstr = @import("smallstring.zig");
const lstr = @import("largestring.zig");

const StringError = bstr.StringError;
const String = bstr.String;
const SmallString = sstr.SmallString;
const LargeString = lstr.LargeString;

comptime {
    if (@sizeOf(SmallString) != @sizeOf(LargeString))
        @compileError("SmallString and LargeString unexpectedly differnt sizes.");
    if (builtin.cpu.arch.endian() != .little)
        @compileError("Currently String only runs on little endian.");
}

// --- Tests ---

const tt = std.testing;
const talloc = &tt.allocator;

test "small copy" {
    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = SmallString.init_copy(hs);
    try tt.expectEqual(@as(u8, @intCast(5)), ss.length());
    try tt.expectEqualSlices(u8, hs, ss.to_slice());
}

test "large copy" {
    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = try LargeString.init_copy(hs, 100, talloc);
    defer ss.deinit(talloc);
    try tt.expectEqualSlices(u8, hs, ss.to_slice());
}

test "small to large" {
    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = SmallString.init_copy(hs);

    var large_str = try LargeString.from_small(&ss, ss.length() * 2, talloc);
    defer large_str.deinit(talloc);
    try tt.expectEqualSlices(u8, h[0..], large_str.to_slice());
}

test "union" {
    const str = String.init();
    try tt.expectEqual(@as(u8, 1), str.lowbyte);
    try tt.expect(str.isSmallStr());
    try tt.expectEqual(@as(u64, 0), str.length());
}

test "small into large into small" {
    const h = "hello";
    var ss = try String.init_copy(h, talloc);

    try ss.into_large(talloc);
    try tt.expect(ss.isLargeStr());
    try tt.expectEqual(@as(u64, 5), ss.length());
    try tt.expectEqualSlices(u8, h[0..], ss.to_slice());

    try ss.into_small(talloc);
    try tt.expect(ss.isSmallStr());
    try tt.expectEqual(@as(u64, 5), ss.length());
    try tt.expectEqualSlices(u8, h[0..], ss.to_slice());
}

test "delete range" {
    const h = "hello";
    var ss = try String.init_copy(h, talloc);

    const h1 = "hllo";
    const h2 = "ho";
    const h3 = "h";

    ss.delete1(100);
    try tt.expectEqualSlices(u8, h[0..], ss.to_slice());
    ss.delete1(1);
    try tt.expectEqualSlices(u8, h1[0..], ss.to_slice());
    ss.delete_range(1, 2);
    try tt.expectEqualSlices(u8, h2[0..], ss.to_slice());
    ss.delete_range(1, 5);
    try tt.expectEqualSlices(u8, h3[0..], ss.to_slice());
}
