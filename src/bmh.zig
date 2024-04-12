const std = @import("std");
const str = @import("string.zig");

const BoyerMooreHorspool = BoyerMooreHorspoolType(null);
const BoyerMooreHorspoolNoCase = BoyerMooreHorspoolType(str.transform_to_lower);

pub fn eql_tr(xs: []const u8, ys: []const u8, comptime tr: str.TransformFunc) bool {
    if (xs.len != ys.len)
        return false;
    for (xs, ys) |x, y| {
        if (tr(x) != tr(y))
            return false;
    }
    return true;
}

pub fn BoyerMooreHorspoolType(comptime tr: ?str.TransformFunc) type {
    return struct {
        const alpha_size = 256;
        const trfn: str.TransformFunc = tr orelse str.transform_ident;

        tab: [alpha_size]usize,
        pat: []const u8,

        pub fn search(pat: []const u8, text: []const u8) usize {
            var t: @This() = undefined;
            t.preprocess(pat);
            return t.match(text);
        }

        pub fn preprocess(this: *@This(), pat: []const u8) void {
            this.pat = pat;
            for (0..this.tab.len) |i| {
                this.tab[i] = pat.len;
            }
            for (0..pat.len - 1) |i| {
                this.tab[trfn(pat[i])] = pat.len - i - 1;
            }
        }

        pub fn match(this: *@This(), text: []const u8) usize {
            var p: usize = 0;
            while (p + this.pat.len <= text.len) {
                if (trfn == str.transform_ident) {
                    if (std.mem.eql(u8, text[p .. p + this.pat.len], this.pat))
                        return p;
                } else {
                    if (eql_tr(text[p .. p + this.pat.len], this.pat, trfn))
                        return p;
                }
                p = p + this.tab[text[p + this.pat.len - 1]];
            }
            return text.len;
        }
    };
}

const tt = std.testing;

test "bmh search" {
    const s = ("1234567890" ** 12) ++ "asdf";
    const r = BoyerMooreHorspool.search("asdf", s);
    try tt.expectEqual(@as(usize, 120), r);
}

test "bmh no case search" {
    const s = ("1234567890" ** 12) ++ "ASdf";
    const r = BoyerMooreHorspoolNoCase.search("aSDf", s);
    try tt.expectEqual(@as(usize, 120), r);
}
