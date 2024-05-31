const std = @import("std");

pub const null_alloc = NullAllocator.init().allocator();

/// An allcator that should never be called. Use this when a function takes
/// an allocator argument, but you know it will never be called. Every
/// call go straight to unreachable so at debug will still panic for you.
pub const NullAllocator = struct {
    pub fn init() @This() {}

    pub fn allocator(self: *@This()) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    pub fn alloc(_: *anyopaque, _: usize, _: u8, _: usize) ?[*]u8 {
        unreachable;
    }

    pub fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
        unreachable;
    }

    fn free(_: *anyopaque, _: []u8, _: u8, _: usize) void {
        unreachable;
    }
};
