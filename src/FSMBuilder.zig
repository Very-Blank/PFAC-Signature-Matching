const std = @import("std");

const ByteBuffer = @import("ByteBuffer.zig");
const FSM = @import("FSM.zig");
const SignatureMap = @import("SignatureMap.zig");
const metrics: bool = @import("build_options").metrics;

signature_to_id_map: std.AutoHashMapUnmanaged(IndirectKey, FSM.SignatureType),
id_to_signature_map: std.AutoHashMapUnmanaged(FSM.SignatureType, IndirectKey),
sorted_buffers: std.ArrayList(ByteBuffer),
signatures: usize,

start_checker: StartChecker,

const Self = @This();

pub const BufferIndex = union(enum) {
    is: usize,
    should: usize,
};

pub const IndirectKey = struct { len: usize, index: usize };

const StartChecker = struct {
    start_map: std.AutoHashMapUnmanaged(u16, void),
    unique_starts: usize,

    const max_unique_starts: usize = FSM.transtitions;

    const empty: StartChecker = .{
        .start_map = .empty,
        .unique_starts = 0,
    };

    pub fn deinit(self: *StartChecker, allocator: std.mem.Allocator) void {
        self.start_map.deinit(allocator);
    }

    pub fn addStart(
        self: *StartChecker,
        allocator: std.mem.Allocator,
        signature: []const u8,
    ) !void {
        const start: u16 = std.mem.bytesToValue(u16, signature[0..2]);
        if (!self.start_map.contains(start)) {
            if (max_unique_starts <= self.unique_starts + 1) return error.TransitionTableFull;

            try self.start_map.put(allocator, start, {});
            self.unique_starts += 1;
        }
    }
};

pub const empty: Self = .{
    .signature_to_id_map = .empty,
    .id_to_signature_map = .empty,
    .sorted_buffers = .empty,
    .signatures = 0,
    .start_checker = .empty,
};

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    for (self.sorted_buffers.items) |*buffers| {
        buffers.deinit(allocator);
    }

    self.sorted_buffers.deinit(allocator);

    self.signature_to_id_map.deinit(allocator);
    self.id_to_signature_map.deinit(allocator);
    self.start_checker.deinit(allocator);
}

pub fn buildFSM(
    self: *Self,
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
) !FSM {
    const start = if (metrics) std.Io.Clock.awake.now(io) else {};

    var fsm: FSM = .{
        .prefix_table = .{([_]FSM.PreStateType{.TrapState} ** FSM.permutations)} ** FSM.permutations,
        .transition_table = [_]FSM.PostStateType{.TrapState} ** FSM.transtitions,
        .signatures = @intCast(self.signatures),
        .postfix_table = undefined,
    };

    var postfix_table_list: std.ArrayList([FSM.permutations]FSM.PostStateType) = .fromOwnedSlice(init: {
        const slice = try allocator.alloc([FSM.permutations]FSM.PostStateType, self.signatures);
        for (slice) |*value| {
            value.* = [_]FSM.PostStateType{.TrapState} ** FSM.permutations;
        }

        break :init slice;
    });

    errdefer postfix_table_list.deinit(allocator);

    var transtition_table_len: usize = 0;

    outer: for (self.sorted_buffers.items) |buffer| {
        std.debug.assert(buffer.element_size >= 2);

        for (0..buffer.len) |i| {
            const signature = buffer.get(i);
            const indirect_key: IndirectKey = .{ .len = buffer.element_size, .index = i };

            var next_state: FSM.PostStateType = init: {
                const first_c = signature[0];
                const second_c = signature[1];

                if (fsm.prefix_table[first_c][second_c] == .TrapState) {
                    fsm.prefix_table[first_c][second_c] = .make(@intCast(transtition_table_len + 1));

                    if (signature.len == 2) {
                        fsm.transition_table[transtition_table_len] = self.signature_to_id_map.get(indirect_key).?.toPostStateType();
                        continue :outer;
                    }

                    try postfix_table_list.append(allocator, [_]FSM.PostStateType{.TrapState} ** FSM.permutations);
                    fsm.transition_table[transtition_table_len] = .make(@intCast(postfix_table_list.items.len));

                    transtition_table_len += 1;
                }

                break :init fsm.transition_table[fsm.prefix_table[first_c][second_c].toTableIndex()];
            };

            for (signature[2 .. signature.len - 1]) |c| {
                if (postfix_table_list.items[next_state.toTableIndex()][c] == .TrapState) {
                    try postfix_table_list.append(allocator, [_]FSM.PostStateType{.TrapState} ** FSM.permutations);
                    postfix_table_list.items[next_state.toTableIndex()][c] = .make(@intCast(postfix_table_list.items.len)); // NOTE: Bias of 1, so not len - 1
                }

                next_state = postfix_table_list.items[next_state.toTableIndex()][c];
            }

            postfix_table_list.items[next_state.toTableIndex()][signature[signature.len - 1]] = self.signature_to_id_map.get(indirect_key).?.toPostStateType();
        }
    }

    fsm.postfix_table = try postfix_table_list.toOwnedSlice(allocator);

    if (metrics) {
        const elapsed = start.untilNow(io, .awake);
        const elapsed_ms = @as(f128, @floatFromInt(elapsed.toNanoseconds())) / 1_000_000;

        try stdout.print("FSM BUILD TIME: {d:.5} ms\n", .{elapsed_ms});
    }

    return fsm;
}

pub fn buildSignatureMap(self: *const Self, allocator: std.mem.Allocator) !SignatureMap {
    std.debug.assert(self.sorted_buffers.items.len > 0);

    var buffer_size: usize = 0;
    for (self.sorted_buffers.items) |buffer| {
        buffer_size += buffer.element_size * buffer.len;
    }

    std.debug.assert(buffer_size > 0);

    var signature_map: SignatureMap = .{
        .id_to_signature_map = .empty,
        .buffers = try allocator.alloc(u8, buffer_size),
    };
    errdefer signature_map.deinit(allocator);

    var current_index: usize = 0;
    for (self.sorted_buffers.items) |buffer| {
        std.debug.assert(buffer.element_size >= 2);

        for (0..buffer.len) |i| {
            try signature_map.id_to_signature_map.put(
                allocator,
                self.signature_to_id_map.get(
                    .{ .len = buffer.element_size, .index = i },
                ).?,
                init: {
                    @memcpy(signature_map.buffers[current_index .. current_index + buffer.element_size], buffer.get(i));
                    break :init signature_map.buffers[current_index .. current_index + buffer.element_size];
                },
            );

            current_index += buffer.element_size;
        }
    }

    return signature_map;
}

pub fn addSignature(
    self: *Self,
    allocator: std.mem.Allocator,
    signature: []const u8,
) !void {
    std.debug.assert(signature.len >= 2);

    try self.start_checker.addStart(allocator, signature);

    if (self.hasSignature(signature)) return error.SignatureExists;

    const signature_index: usize = init: switch (self.findBufferByLen(signature.len)) {
        .is => |capture| {
            try self.sorted_buffers.items[capture].append(allocator, signature);
            break :init self.sorted_buffers.items[capture].len - 1;
        },
        .should => |capture| {
            try self.sorted_buffers.insert(allocator, capture, try ByteBuffer.init(allocator, signature));
            break :init 0;
        },
    };

    self.signatures += 1;

    const signature_id: FSM.SignatureType = .make(@intCast(self.signatures));
    try self.signature_to_id_map.put(allocator, .{ .len = signature.len, .index = signature_index }, signature_id);
    try self.id_to_signature_map.put(allocator, signature_id, .{ .len = signature.len, .index = signature_index });
}

pub fn getSignature(self: *const Self, state: FSM.PostStateType) []const u8 {
    const signature_location = self.id_to_signature_map.get(state.toSignatureType(@intCast(self.signatures))).?;
    return switch (self.findBufferByLen(signature_location.len)) {
        .is => |capture| self.sorted_buffers.items[capture].get(signature_location.index),
        else => unreachable,
    };
}

pub fn hasSignature(self: *const Self, signature: []const u8) bool {
    switch (self.findBufferByLen(signature.len)) {
        .is => |capture| {
            for (0..self.sorted_buffers.items[capture].len) |i| {
                if (std.mem.eql(u8, self.sorted_buffers.items[capture].get(i), signature)) return true;
            }
        },
        .should => {},
    }

    return false;
}

pub fn getIndirectKey(self: *const Self, signature: []const u8) IndirectKey {
    switch (self.findBufferByLen(signature.len)) {
        .is => |capture| {
            for (0..self.sorted_buffers.items[capture].len) |i| {
                if (std.mem.eql(u8, self.sorted_buffers.items[capture].get(i), signature)) return IndirectKey{ .len = signature.len, .index = i };
            }

            unreachable;
        },
        .should => unreachable,
    }
}

/// Returns either the index where buffer that has the len is or where it should be.
fn findBufferByLen(self: *const Self, len: usize) BufferIndex {
    if (self.sorted_buffers.items.len == 0) return .{ .should = 0 };
    var lower_bound: usize = 0;
    var higher_bound: usize = self.sorted_buffers.items.len;

    while (lower_bound < higher_bound) {
        const middle: usize = (lower_bound >> 1) + (higher_bound >> 1);
        if (self.sorted_buffers.items[middle].element_size < len) {
            lower_bound = middle + 1;
            continue;
        }

        higher_bound = middle;
    }

    if (self.sorted_buffers.items.len <= lower_bound or self.sorted_buffers.items[lower_bound].element_size != len) return .{ .should = lower_bound };

    return .{ .is = lower_bound };
}
