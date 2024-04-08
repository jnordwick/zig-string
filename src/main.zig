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
    if (builtin.cpu.arch.endian() != .Little)
        @compileError("Currently String only runs on little endian.");
}

// --- Tests ---

const tt = std.testing;
var testalloc = std.testing.allocator;
var talloc = &testalloc;

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
