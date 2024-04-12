const std = @import("std");

const ShiftOr = ShiftOrType(u64, null);

const TransformFunc = fn (char: u8) callconv(.Inline) u8;

const to_lower_map: [256]u8 = b: {
    var map: [256]u8 = [_]u8{0} ** 256;
    for (0..256) |i| {
        var c: u8 = @intCast(i);
        if (c >= 'A' and c <= 'Z')
            c = (c - 'A') + 'a';
        map[i] = c;
    }
    break :b map;
};

/// transformer to map everything to lowercase
pub inline fn transform_to_lower(c: u8) u8 {
    return to_lower_map[c];
}

pub inline fn transform_ident(c: u8) u8 {
    return c;
}

/// Create a Shoft Or matcher. This is a bit parallelism string matcher
/// that runs in O(n) time where n is the length of the text. There is
/// a preprocessing step that runs in O(m) time where m is the length
/// of the pattern. It only needs to be run once for the pattern and
/// can be reused on diffent texts. While the big-O notation isn't
/// impressive it gains its performane from each character only needed
/// a single compare that fits into a register (as long as MaskT fits
/// in a register). There is no backtracking. A table lookup does need
/// to occur, but if this type is places on the stack, it will easily be
/// in the L1 cache. This is an excellent matcher for short strings. For
/// a 64 bit machine, a u64 or smaller is recommended, but with the
/// larger simd registers u128 and larger should still perform decently.
///
/// Instances of this aren't meant to be reused. Just assign on top of them
/// or zero them to clear.
///
/// MaskT: An unsigned integer type that has bit width the length of the
/// longest pattern the matcher will work with.
/// tr: An inlineable function body that all characters will be filtered
/// trough. It filters both the pattern and the text. see: transform_to_lower
pub fn ShiftOrType(comptime MaskT: type, comptime tr: ?TransformFunc) type {
    const ti = @typeInfo(MaskT);
    if (ti != .Int or ti.Int.signedness != .unsigned)
        @compileError("ShiftOr MaskT must be an unsigned int with bit width of at least the max pattern length.");

    return struct {
        pub const Mask = MaskT;
        pub const mask_bits = @typeInfo(Mask).Int.bits;
        pub const Shift = std.math.Log2Int(Mask);

        pub const trfn: TransformFunc = tr orelse transform_ident;

        mask: [256]Mask = [_]Mask{0} ** 256,
        final: Mask = undefined,
        patlen: usize = undefined,

        /// search for pattern in text. This does both the preprocessing step
        /// and the matching step, but throws away the preprocessing table.
        /// If you will only use the pattern once or aren't concerned about
        /// high performance, this is the easy way.
        ///
        /// pattern: the text to search for. pattern.len must not be larger
        /// than the bit width of the Mask type.
        /// text: text to search in. Can be any length.
        /// return: the index of the first occurance of the pattern. returns
        /// text.length on failure.
        pub fn search(pattern: []const u8, text: []const u8) usize {
            var t = @This(){};
            t.preprocess(pattern);
            return t.match(text);
        }

        /// The preprocessing step. Generates a mask array of 256 elements
        /// of the Mask type. This should only be run once. To use another
        /// pattern zero the instance first.
        ///
        /// pattern: the text to search for. pattern.len must not be larger
        /// than the bit width of the Mask type.
        pub fn preprocess(this: *@This(), pattern: []const u8) void {
            std.debug.assert(pattern.len > 0 and pattern.len <= mask_bits);
            this.patlen = pattern.len;
            this.final = @as(Mask, 1) << @as(Shift, @intCast(this.patlen - 1));
            for (0..pattern.len) |i| {
                const shift = @as(Mask, 1) << @as(Shift, @intCast(i));
                this.mask[trfn(pattern[i])] = this.mask[trfn(pattern[i])] | shift;
            }
        }

        /// Match text against the already preprocessed pattern. This should
        /// only be called after preprocess has been given a pattern.
        ///
        /// text: can be any length
        /// return: the index of the first occurance of the pattern. returns
        /// text.length on failure.
        pub fn match(this: *const @This(), text: []const u8) usize {
            var state: Mask = 0;
            for (0..text.len) |i| {
                state = (state << 1) + 1;
                state = state & this.mask[trfn(text[i])];
                if (state & this.final != 0) {
                    return i - this.patlen + 1;
                }
            }
            return text.len;
        }
    };
}

const tt = std.testing;

test "search" {
    var s = "wkkcjehasdfwecwee";
    var r = ShiftOr.search("asdf", s);
    try tt.expectEqual(@as(usize, 7), r);

    s = "wkkcjehasxfwecwee";
    r = ShiftOr.search("asdf", s);
    try tt.expectEqual(@as(usize, s.len), r);
}

test "seach32 caseless" {
    const SO = ShiftOrType(u32, transform_to_lower);
    var s = "wkkCjehAsdFWECwee";
    var r = SO.search("aSDf", s);
    try tt.expectEqual(@as(usize, 7), r);

    s = "wkkcjehasxfwecwee";
    r = SO.search("asdf", s);
    try tt.expectEqual(@as(usize, s.len), r);
}

test "search128" {
    const SO = ShiftOrType(u128, null);
    var s = ("1234567890" ** 12) ++ "asdf";
    var r = SO.search("asdf", s);
    try tt.expectEqual(@as(usize, 120), r);

    s = ("1234567890" ** 12) ++ "asdf";
    r = SO.search("asdq", s);
    try tt.expectEqual(@as(usize, s.len), r);
}
