const std = @import("std");

const hip = @import("hip");
const builtin = @import("builtin");

pub fn hipMalloc(len: usize) !*anyopaque {
    var device_buffer: ?*anyopaque = undefined;
    try wrapError(hip.hipMalloc(&device_buffer, len));

    if (device_buffer) |capture| return capture;

    return error.DeviceNullPointer;
}

/// All of the possible hip errors that are currently in ROCM hip.
pub const HipError = error{NotSuccess};

/// wrapError calls bubbleWrap() but also on debug and safe builds calls synchronizeHipDevice,
/// to catch errors that might have happened after an operation was called.
pub fn wrapError(@"error": u32) HipError!void {
    try bubbleWrap(@"error");

    switch (builtin.mode) {
        .Debug, .ReleaseSafe => try bubbleWrap(hip.hipDeviceSynchronize()),
        else => {},
    }
}

/// bubbleWrap converts hip errors to zig errors, so
/// you can use the langauge's error handeling features.
pub fn bubbleWrap(@"error": u32) HipError!void {
    if (@"error" == 0) return;

    std.debug.print("Hip error: {s} ({any})\nMessage: {s}\n", .{
        error_code: {
            const null_ternimated = hip.hipGetErrorName(@"error");
            const len = std.mem.findSentinel(u8, 0, null_ternimated);

            // Strip the "hipError" prefix.
            if ("hipError".len < len) break :error_code null_ternimated["hipError".len..len];
            break :error_code null_ternimated[0..len];
        },
        @"error",
        error_message: {
            const null_ternimated = hip.hipGetErrorString(@"error");

            break :error_message null_ternimated[0..std.mem.findSentinel(u8, 0, null_ternimated)];
        },
    });

    return HipError.NotSuccess;
}
