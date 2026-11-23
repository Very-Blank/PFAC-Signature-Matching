const std = @import("std");
const FSM = @import("FSM.zig");

id_to_signature_map: std.AutoHashMapUnmanaged(FSM.SignatureType, []const u8),
buffers: []u8,

const Self = @This();

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.id_to_signature_map.deinit(allocator);

    allocator.free(self.buffers);
}

pub inline fn getSignatureName(self: *const Self, signature: FSM.SignatureType) []const u8 {
    return self.id_to_signature_map.get(signature).?;
}
