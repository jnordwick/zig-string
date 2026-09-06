const std = @import("std");
const builtin = @import("builtin");

pub const bstr = @import("root.zig");
pub const sstr = @import("smallstring.zig");
pub const lstr = @import("largestring.zig");
pub const bmh = @import("bmh.zig");
pub const sor = @import("shiftor.zig");

const StringError = bstr.StringError;
const String = bstr.String;
const SmallString = sstr.SmallString;
const LargeString = lstr.LargeString;

comptime {
    // Force analysis of all imported modules so their tests are included.
    _ = bstr;
    _ = sstr;
    _ = lstr;
    _ = bmh;
    _ = sor;

    if (@sizeOf(SmallString) != @sizeOf(LargeString))
        @compileError("SmallString and LargeString unexpectedly different sizes.");
    if (builtin.cpu.arch.endian() != .little)
        @compileError("Currently String only runs on little endian.");
}

// --- Tests ---

const tt = std.testing;
const talloc = tt.allocator;

test "small copy" {
    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = SmallString.from_slice(hs);
    try tt.expectEqual(@as(u8, @intCast(5)), ss.len);
    try tt.expectEqualSlices(u8, hs, ss.const_slice());
}

test "large copy" {
    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = try LargeString.from_slice(talloc, hs, 100);
    defer ss.deinit(talloc);
    try tt.expectEqualSlices(u8, hs, ss.const_slice());
}

test "small to large" {
    const h = "hello";
    const hs: []const u8 = h[0..];
    var ss = SmallString.from_slice(hs);

    var large_str = try LargeString.from_small(talloc, &ss, ss.len * 2);
    defer large_str.deinit(talloc);
    try tt.expectEqualSlices(u8, h[0..], large_str.const_slice());
}

test "small into large into small" {
    const h = "hello";
    var ss = try String.from_slice(talloc, h);

    try ss.into_large(talloc);
    try tt.expect(!ss.is_small());
    try tt.expectEqual(@as(u32, 5), ss.length());
    try tt.expectEqualSlices(u8, h[0..], ss.const_slice());

    try ss.into_small(talloc);
    try tt.expect(ss.is_small());
    try tt.expectEqual(@as(u32, 5), ss.length());
    try tt.expectEqualSlices(u8, h[0..], ss.const_slice());
}

test "delete range" {
    const h = "hello";
    var ss = try String.from_slice(talloc, h);

    const h1 = "hllo";
    const h2 = "ho";
    const h3 = "h";

    ss.delete(100);
    try tt.expectEqualSlices(u8, h[0..], ss.const_slice());
    ss.delete(1);
    try tt.expectEqualSlices(u8, h1[0..], ss.const_slice());
    ss.delete_range(1, 2);
    try tt.expectEqualSlices(u8, h2[0..], ss.const_slice());
    ss.delete_range(1, 5);
    try tt.expectEqualSlices(u8, h3[0..], ss.const_slice());
}
