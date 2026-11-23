const std = @import("std");
const hip = @import("hip");
const hh = @import("hiphelpers.zig");

const SignatureMap = @import("SignatureMap.zig");
const Matches = @import("Matches.zig");

prefix_table: [permutations][permutations]PreStateType,
transition_table: [transtitions]PostStateType,
postfix_table: [][permutations]PostStateType,
signatures: u16,

const Self = @This();

pub const permutations = 1 << 8;
pub const transtitions = hip.TRANSITIONS; // Zero is used for TRAP_STATE

pub const PreStateType = enum(u8) {
    TrapState = 0,
    _,

    pub inline fn make(int: u16) PreStateType {
        std.debug.assert(int != 0);

        return @enumFromInt(int);
    }

    pub inline fn toTableIndex(@"enum": PreStateType) usize {
        std.debug.assert(@"enum" != .TrapState);

        return @intFromEnum(@"enum") - 1;
    }
};

pub const PostStateType = enum(u16) {
    TrapState = 0,
    _,

    pub inline fn make(int: u16) PostStateType {
        std.debug.assert(int != 0);

        return @enumFromInt(int);
    }

    pub inline fn toTableIndex(@"enum": PostStateType) usize {
        std.debug.assert(@"enum" != .TrapState);

        return @intFromEnum(@"enum") - 1;
    }

    pub inline fn isSignatureType(@"enum": PostStateType, signatures: u16) bool {
        std.debug.assert(@"enum" != .TrapState);
        return @intFromEnum(@"enum") <= signatures;
    }

    pub inline fn toSignatureType(@"enum": PostStateType, signatures: u16) SignatureType {
        std.debug.assert(isSignatureType(@"enum", signatures));

        return @enumFromInt(@intFromEnum(@"enum"));
    }
};

pub const SignatureType = enum(u16) {
    Invalid = 0,
    _,

    pub inline fn make(int: u16) SignatureType {
        std.debug.assert(int != 0);

        return @enumFromInt(int);
    }

    pub inline fn toPostStateType(@"enum": SignatureType) PostStateType {
        std.debug.assert(@"enum" != .Invalid);

        return @enumFromInt(@intFromEnum(@"enum"));
    }
};

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.postfix_table);
    self.postfix_table = undefined;
}

pub fn deviceCopy(self: *const Self) !*anyopaque {
    const device_fsm: *anyopaque = try hh.hipMalloc(@sizeOf(@FieldType(Self, "prefix_table")) +
        @sizeOf(@FieldType(Self, "transition_table")) +
        @sizeOf([permutations]PostStateType) * self.postfix_table.len);

    errdefer _ = hip.hipFree(device_fsm);

    try hh.wrapError(hip.hipMemcpy(
        device_fsm,
        &self.prefix_table,
        @sizeOf(@FieldType(Self, "prefix_table")),
        hip.hipMemcpyHostToDevice,
    ));

    try hh.wrapError(hip.hipMemcpy(
        @as([*]u8, @ptrCast(device_fsm)) + @sizeOf(@FieldType(Self, "prefix_table")),
        &self.transition_table,
        @sizeOf(@FieldType(Self, "transition_table")),
        hip.hipMemcpyHostToDevice,
    ));

    try hh.wrapError(hip.hipMemcpy(
        @as([*]u8, @ptrCast(device_fsm)) + @sizeOf(@FieldType(Self, "prefix_table")) + @sizeOf(@FieldType(Self, "transition_table")),
        self.postfix_table.ptr,
        @sizeOf([permutations]PostStateType) * self.postfix_table.len,
        hip.hipMemcpyHostToDevice,
    ));

    return device_fsm;
}

pub fn match(self: *const Self, data: []const u8, matches: *Matches) void {
    std.debug.assert(data.len >= 2);
    outer: for (0..data.len - 1) |offset| {
        const first_c = data[offset];
        const second_c = data[offset + 1];

        if (self.prefix_table[first_c][second_c] == .TrapState) {
            continue :outer;
        }

        var current_state: PostStateType = self.transition_table[self.prefix_table[first_c][second_c].toTableIndex()];

        for (data[offset + 2 .. data.len]) |c| {
            if (current_state.isSignatureType(self.signatures)) {
                if (matches.count < matches.ids.len) {
                    matches.ids[matches.count] = current_state.toSignatureType(self.signatures);
                }

                matches.count += 1;
            }

            current_state = self.postfix_table[current_state.toTableIndex()][c];
            if (current_state == .TrapState) continue :outer;
        }

        if (current_state.isSignatureType(self.signatures)) {
            if (matches.count < matches.ids.len) {
                matches.ids[matches.count] = current_state.toSignatureType(self.signatures);
            }

            matches.count += 1;
        }
    }
}

pub fn fromBytes(bytes: []u8, allocator: std.mem.Allocator) !Self {
    const prefix_size: usize = @sizeOf(@FieldType(Self, "prefix_table"));
    const transition_size: usize = @sizeOf(@FieldType(Self, "transition_table"));
    const signatures = std.mem.bytesToValue(@FieldType(Self, "signatures"), bytes[prefix_size + transition_size .. prefix_size + transition_size + @sizeOf(@FieldType(Self, "signatures"))]);

    if (signatures == 0) return error.InvalidFSM;
    if (bytes.len < prefix_size + transition_size + @as(usize, signatures) * permutations) return error.InvalidFSM;
    if ((bytes.len - prefix_size + transition_size + @sizeOf(@FieldType(Self, "signatures"))) % (permutations << 1) != 0) return error.InvalidFSM;

    return .{
        .prefix_table = std.mem.bytesToValue(@FieldType(Self, "prefix_table"), bytes[0..prefix_size]),
        .transition_table = std.mem.bytesToValue(
            @FieldType(Self, "transition_table"),
            bytes[prefix_size .. prefix_size + transition_size],
        ),
        .signatures = signatures,
        .postfix_table = init: {
            const postfix_slice: [][permutations]PostStateType = @ptrCast(@alignCast(bytes[prefix_size + transition_size + @sizeOf(@FieldType(Self, "signatures")) ..]));
            const buffer = try allocator.alloc([permutations]PostStateType, postfix_slice.len);
            @memcpy(buffer, postfix_slice);
            break :init buffer;
        },
    };
}
