const std = @import("std");

const ShiftOr = struct {
    mask: [256]u64 = [_]u64{0} ** 256,
    patlen: u64 = 0,
    final: u64 = 0,

    pub fn search(pattern: []const u8, text: []const u8) u64 {
        var t = @This(){};
        t.gen_mask(pattern);
        return t.match(text);
    }

    pub fn gen_mask(this: *@This(), pattern: []const u8) void {
        std.debug.assert(pattern.len > 0 and pattern.len < 64);
        this.patlen = pattern.len;
        this.final = @as(u64, 1) << @as(u6, @intCast(this.patlen - 1));
        for (0..pattern.len) |i| {
            const shift = @as(u64, 1) << @as(u6, @intCast(i));
            this.mask[pattern[i]] = this.mask[pattern[i]] | shift;
        }
    }

    pub fn match(this: *const @This(), text: []const u8) u64 {
        var state: u64 = 0;
        for (0..text.len) |i| {
            state = (state << 1) + 1;
            state = state & this.mask[text[i]];
            if (state & this.final != 0) {
                return i - this.patlen + 1;
            }
        }
        return text.len;
    }
};

const tt = std.testing;

test "search" {
    var s = "wkkcjehasdfwecwee";
    var r = ShiftOr.search("asdf", s);
    try tt.expectEqual(@as(u64, 7), r);

    s = "wkkcjehasxfwecwee";
    r = ShiftOr.search("asdf", s);
    try tt.expectEqual(@as(u64, s.len), r);
}
