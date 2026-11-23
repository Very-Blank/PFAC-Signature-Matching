const std = @import("std");

buffer: []u8,
len: usize,

element_size: usize,

const initial_capacity = 1;

const Self = @This();

pub fn init(allocator: std.mem.Allocator, signature: []const u8) !Self {
    return .{
        .buffer = init: {
            const buffer: []u8 = try allocator.alloc(u8, initial_capacity * signature.len);
            @memcpy(buffer[0..signature.len], signature);
            break :init buffer;
        },
        .element_size = signature.len,
        .len = 1,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.buffer);
    self.buffer = undefined;
}

pub fn append(self: *Self, allocator: std.mem.Allocator, signature: []const u8) !void {
    std.debug.assert(signature.len == self.element_size);

    if ((self.len + 1) * self.element_size <= self.buffer.len) {
        const offset = self.len * self.element_size;

        @memcpy(self.buffer[offset .. offset + self.element_size], signature);
        self.len += 1;

        return;
    }

    const prior_len = self.buffer.len;
    const buffer: []u8 = try allocator.alloc(u8, prior_len * 2);
    @memcpy(buffer[0..prior_len], self.buffer);
    allocator.free(self.buffer);

    self.buffer = buffer;
    @memcpy(self.buffer[prior_len .. prior_len + self.element_size], signature);

    self.len += 1;
}

pub fn get(self: *const Self, index: usize) []const u8 {
    std.debug.assert(index < self.len);
    return self.buffer[index * self.element_size .. (index + 1) * self.element_size];
}
