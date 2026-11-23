const std = @import("std");
const hip = @import("hip");
const builtin = @import("builtin");

const hh = @import("hiphelpers.zig");
const argp = @import("argparsing.zig");

const Io = std.Io;

const FSMBuilder = @import("FSMBuilder.zig");
const SignatureMap = @import("SignatureMap.zig");
const FSM = @import("FSM.zig");
const Matches = @import("Matches.zig");

const metrics: bool = @import("build_options").metrics;

// NOTE: We seperate the main and the programs functionality for testing purposes.
pub fn main(init: std.process.Init) !u8 {
    const allocator = init.gpa;
    const arena_allocator = init.arena.allocator();

    const io = init.io;

    var stdout_buffer: [1024]u8 = .{0} ** 1024;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout: *std.Io.Writer = &stdout_writer.interface;
    defer stdout.flush() catch unreachable;

    var stderr_buffer: [1024]u8 = .{0} ** 1024;
    var stderr_writer = std.Io.File.stdout().writerStreaming(io, &stderr_buffer);
    const stderr: *std.Io.Writer = &stderr_writer.interface;
    defer stderr.flush() catch unreachable;

    var stdin_buffer: [1024]u8 = .{0} ** 1024;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdin: *std.Io.Reader = &stdin_reader.interface;

    const args: []const [:0]const u8 = (try init.minimal.args.toSlice(arena_allocator))[1..];

    return try scan(args, allocator, io, Io.Dir.cwd(), stdin, stdout, stderr);
}

pub fn scan(args: []const [:0]const u8, allocator: std.mem.Allocator, io: Io, cwd: Io.Dir, stdin: *std.Io.Reader, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !u8 {
    const settings = argp.parseArgs(args, allocator, stdout, stderr) catch |err| switch (err) {
        error.Help => return 0,
        else => return 1,
    };

    defer switch (settings.mode) {
        .scan => |scan_capture| switch (scan_capture.sources) {
            .paths => |paths_capture| allocator.free(paths_capture.source),
            else => {},
        },
        else => {},
    };

    var fsm: FSM, var signature_map: ?SignatureMap = init_fsm: {
        switch (settings.fsm_source) {
            .singatures => |capture| {
                const signatures: std.json.Parsed([][]const u8), const buffer: []const u8 = init_signatures: {
                    const buffer: []u8 = init_buffer: switch (capture) {
                        .path => |path| break :init_buffer cwd.readFileAlloc(io, path, allocator, .unlimited) catch |err| {
                            try stderr.print("error: {s}, while opening file {s}.\n", .{ @errorName(err), path });
                            return 1;
                        },
                        .stdin => {
                            break :init_buffer try stdin.allocRemaining(allocator, .unlimited);
                        },
                    };

                    errdefer allocator.free(buffer);

                    break :init_signatures .{ std.json.parseFromSlice(
                        [][]const u8,
                        allocator,
                        buffer,
                        .{},
                    ) catch |err| {
                        try stderr.print("error: {s}, while reading signatures file.\n", .{@errorName(err)});
                        return 1;
                    }, buffer };
                };

                defer {
                    signatures.deinit();
                    allocator.free(buffer);
                }

                var builder: FSMBuilder = .empty;
                defer builder.deinit(allocator);

                for (signatures.value) |signature| {
                    builder.addSignature(allocator, signature) catch |err| switch (err) {
                        error.SignatureExists => {},
                        else => return err,
                    };
                }

                break :init_fsm .{ try builder.buildFSM(io, allocator, stdout), try builder.buildSignatureMap(allocator) };
            },
            .stdin => {
                const buffer = try stdin.allocRemaining(allocator, .unlimited);
                defer allocator.free(buffer);

                break :init_fsm .{ try FSM.fromBytes(buffer, allocator), null };
            },
        }
    };

    defer {
        fsm.deinit(allocator);

        if (signature_map) |*capture| {
            capture.deinit(allocator);
        }
    }

    switch (settings.mode) {
        .scan => |scan_capture| {
            var matches: Matches = .{
                .count = 0,
                .ids = if (scan_capture.capacity == 0) &.{} else try allocator.alloc(FSM.SignatureType, scan_capture.capacity),
            };

            defer if (scan_capture.capacity != 0) allocator.free(matches.ids);

            switch (scan_capture.device) {
                .cpu => switch (scan_capture.sources) {
                    .stdin => {
                        const blob = try stdin.allocRemaining(allocator, .unlimited);
                        defer allocator.free(blob);

                        try matchCpu(io, stdout, &fsm, blob, &matches);
                    },
                    .paths => |paths_capture| {
                        var blob: []u8 = try allocator.alloc(u8, 1 << 10);
                        defer allocator.free(blob);
                        var size: usize = 0;

                        for (paths_capture.source) |path| switch ((cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
                            try stderr.print("error: {s}, while trying to get {s} stat's.\n", .{ @errorName(err), path });
                            continue;
                        }).kind) {
                            .file => {
                                const file = cwd.openFile(io, path, .{}) catch |err| {
                                    try stderr.print("error: {s}, while opening file {s}.\n", .{ @errorName(err), path });
                                    continue;
                                };

                                defer file.close(io);

                                size = try file.length(io);
                                if (size == 0) continue;

                                if (blob.len < size) {
                                    blob = init: {
                                        const new_blob = try allocator.alloc(u8, size);
                                        allocator.free(blob);
                                        break :init new_blob;
                                    };
                                }

                                _ = try file.readPositionalAll(io, blob, 0);

                                try matchCpu(io, stdout, &fsm, blob[0..size], &matches);
                            },
                            .directory => {
                                if (paths_capture.recursive) {
                                    const dir = try cwd.openDir(io, path, .{ .iterate = true });
                                    defer dir.close(io);
                                    var walker: Io.Dir.Walker = try dir.walk(allocator);
                                    defer walker.deinit();

                                    while (try walker.next(io)) |entry| {
                                        if (entry.kind != .file) continue;

                                        const file = entry.dir.openFile(io, entry.basename, .{}) catch |err| {
                                            try stderr.print("error: {s}, while opening file {s}.\n", .{ @errorName(err), path });
                                            continue;
                                        };

                                        defer file.close(io);

                                        size = try file.length(io);
                                        if (size == 0) continue;

                                        if (blob.len < size) {
                                            blob = init: {
                                                const new_blob = try allocator.alloc(u8, size);
                                                allocator.free(blob);
                                                break :init new_blob;
                                            };
                                        }

                                        _ = try file.readPositionalAll(io, blob, 0);

                                        try matchCpu(io, stdout, &fsm, blob[0..size], &matches);
                                    }
                                } else {
                                    try stderr.print("error: {s}, is a directory.\n", .{path});
                                }
                            },
                            else => {},
                        };
                    },
                },
                .gpu => |gpu_capture| {
                    var gpu_ctx: GpuContext = init_gpu_ctx: {
                        const stream: hip.hipStream_t = init_stream: {
                            var stream: hip.hipStream_t = undefined;
                            try hh.wrapError(hip.hipStreamCreate(&stream));
                            break :init_stream stream;
                        };

                        errdefer _ = hip.hipStreamDestroy(stream);

                        const max_threads: usize = init_max_threads: {
                            var max_threads: i32 = 0;
                            try hh.wrapError(hip.hipDeviceGetAttribute(&max_threads, hip.hipDeviceAttributeMaxThreadsPerBlock, 0));
                            break :init_max_threads @intCast(max_threads);
                        };

                        const device_fsm: *anyopaque = try fsm.deviceCopy();
                        errdefer _ = hip.hipFree(device_fsm);

                        const device_matches: *anyopaque = init_matches: {
                            const device_buffer = try hh.hipMalloc(@sizeOf(hip.Matches));
                            errdefer _ = hip.hipFree(device_buffer);

                            const value: hip.Matches = .{
                                .count = 0,
                                .capacity = scan_capture.capacity,
                                .ids = @ptrCast(@alignCast(try hh.hipMalloc(@sizeOf(u16) * scan_capture.capacity))),
                            };

                            errdefer _ = hip.hipFree(value.ids);

                            try hh.wrapError(hip.hipMemcpy(
                                device_buffer,
                                &value,
                                @sizeOf(hip.Matches),
                                hip.hipMemcpyHostToDevice,
                            ));

                            break :init_matches device_buffer;
                        };

                        errdefer _ = hip.hipFree(device_matches);

                        break :init_gpu_ctx .{
                            .device_fsm = device_fsm,
                            .stream = stream,
                            .device_matches = device_matches,
                            .max_threads = max_threads,
                            .signatures = fsm.signatures,
                            .blob = undefined,
                            .device_blob = undefined,
                            .size = 0,
                        };
                    };

                    defer {
                        _ = hip.hipStreamDestroy(gpu_ctx.stream);
                        _ = hip.hipFree(gpu_ctx.device_fsm);
                        _ = hip.hipFree(gpu_ctx.device_matches);
                    }

                    if (gpu_capture.warm_up) {
                        hip.warm_up();
                    }

                    switch (scan_capture.sources) {
                        .stdin => {
                            gpu_ctx.blob = try stdin.allocRemaining(allocator, .unlimited);
                            gpu_ctx.size = gpu_ctx.blob.len;

                            defer {
                                allocator.free(gpu_ctx.blob);
                                gpu_ctx.device_blob = undefined;
                            }

                            gpu_ctx.device_blob = try hh.hipMalloc(gpu_ctx.blob.len);
                            defer {
                                _ = hip.hipFree(gpu_ctx.device_blob);
                                gpu_ctx.device_blob = undefined;
                            }

                            try hh.wrapError(hip.hipMemcpy(
                                gpu_ctx.device_blob,
                                gpu_ctx.blob.ptr,
                                gpu_ctx.size,
                                hip.hipMemcpyHostToDevice,
                            ));

                            try matchGpu(io, stdout, gpu_ctx);
                        },
                        .paths => |paths_capture| {
                            gpu_ctx.blob = try allocator.alloc(u8, 1 << 10);
                            defer {
                                allocator.free(gpu_ctx.blob);
                                gpu_ctx.device_blob = undefined;
                            }

                            gpu_ctx.device_blob = try hh.hipMalloc(1 << 10);
                            defer {
                                _ = hip.hipFree(gpu_ctx.device_blob);
                                gpu_ctx.device_blob = undefined;
                            }

                            for (paths_capture.source) |path| switch ((cwd.statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
                                try stderr.print("error: {s}, while trying to get {s} stat's.\n", .{ @errorName(err), path });
                                continue;
                            }).kind) {
                                .file => {
                                    const file = cwd.openFile(io, path, .{}) catch |err| {
                                        try stderr.print("error: {s}, while opening file {s}.\n", .{ @errorName(err), path });
                                        continue;
                                    };

                                    defer file.close(io);
                                    gpu_ctx.size = try file.length(io);

                                    if (gpu_ctx.size == 0) continue;

                                    try fileReadGpu(io, allocator, file, &gpu_ctx);
                                    try matchGpu(io, stdout, gpu_ctx);
                                },
                                .directory => {
                                    if (paths_capture.recursive) {
                                        const dir = try cwd.openDir(io, path, .{ .iterate = true });
                                        defer dir.close(io);
                                        var walker: Io.Dir.Walker = try dir.walk(allocator);
                                        defer walker.deinit();

                                        while (try walker.next(io)) |entry| {
                                            if (entry.kind != .file) continue;

                                            const file = entry.dir.openFile(io, entry.basename, .{}) catch |err| {
                                                try stderr.print("error: {s}, while opening file {s}.\n", .{ @errorName(err), path });
                                                continue;
                                            };

                                            defer file.close(io);
                                            gpu_ctx.size = try file.length(io);

                                            if (gpu_ctx.size == 0) continue;

                                            try fileReadGpu(io, allocator, file, &gpu_ctx);
                                            try matchGpu(io, stdout, gpu_ctx);
                                        }
                                    } else {
                                        try stderr.print("error: {s}, is a directory.\n", .{path});
                                    }
                                },
                                else => {},
                            };
                        },
                    }

                    try hh.wrapError(hip.hipMemcpy(
                        &matches.count,
                        &@as(*hip.Matches, @ptrCast(@alignCast(gpu_ctx.device_matches))).count,
                        @sizeOf(usize),
                        hip.hipMemcpyDeviceToHost,
                    ));

                    try hh.wrapError(hip.hipMemcpy(
                        matches.ids.ptr,
                        @as(*hip.Matches, @ptrCast(@alignCast(gpu_ctx.device_matches))).ids,
                        @sizeOf(FSM.SignatureType) * matches.ids.len,
                        hip.hipMemcpyDeviceToHost,
                    ));
                },
            }

            scan_state: switch (scan_capture.output) {
                .Both, .Count => |output_capture| {
                    try stdout.print("{d}\n", .{matches.count});

                    if (output_capture == .Both) continue :scan_state .List;
                },
                .List => {
                    if (signature_map) |map| {
                        for (0..@min(scan_capture.capacity, matches.count)) |match_index| {
                            try stdout.print("{s}\n", .{map.getSignatureName(matches.ids[match_index])});
                        }

                        break :scan_state;
                    }

                    for (0..@min(scan_capture.capacity, matches.count)) |match_index| {
                        try stdout.print("{d}\n", .{matches.ids[match_index]});
                    }
                },
            }
        },
        .@"export" => {
            try stdout.writeAll(std.mem.asBytes(&fsm.prefix_table));
            try stdout.writeAll(std.mem.asBytes(&fsm.transition_table));
            try stdout.writeAll(std.mem.asBytes(&fsm.signatures));
            try stdout.writeAll(@as([*]const u8, @ptrCast(fsm.postfix_table.ptr))[0 .. @sizeOf(FSM.PostStateType) * FSM.permutations * fsm.postfix_table.len]);
        },
    }

    return 0;
}

const GpuContext = struct {
    device_fsm: *anyopaque,
    device_matches: *anyopaque,
    device_blob: *anyopaque,
    stream: hip.hipStream_t,
    blob: []u8,
    size: usize,
    max_threads: usize,
    signatures: u16,
};

inline fn fileReadGpu(
    io: Io,
    allocator: std.mem.Allocator,
    file: Io.File,
    ctx: *GpuContext,
) !void {
    if (ctx.blob.len < ctx.size) {
        ctx.blob = init: {
            const new_blob = try allocator.alloc(u8, ctx.size);
            allocator.free(ctx.blob);
            break :init new_blob;
        };

        ctx.device_blob = init: {
            const new_device_blob: *anyopaque = try hh.hipMalloc(ctx.size);
            _ = hip.hipFree(ctx.device_blob);
            break :init new_device_blob;
        };
    }

    _ = try file.readPositionalAll(io, ctx.blob, 0);

    try hh.wrapError(hip.hipMemcpy(
        ctx.device_blob,
        ctx.blob.ptr,
        ctx.size,
        hip.hipMemcpyHostToDevice,
    ));
}

inline fn matchCpu(io: Io, stdout: *std.Io.Writer, fsm: *const FSM, blob: []const u8, matches: *Matches) !void {
    const start = if (metrics) std.Io.Clock.awake.now(io) else {};

    fsm.match(blob, matches);

    if (metrics) {
        const elapsed = start.untilNow(io, .awake);
        const elapsed_ms = @as(f128, @floatFromInt(elapsed.toNanoseconds())) / 1_000_000;
        const elapsed_s = elapsed_ms / 1000;

        const gb = @as(f128, @floatFromInt(blob.len)) / 1_000_000_000;

        try stdout.print("CPU TIME: {d:.5} ms\n", .{elapsed_ms});
        try stdout.print("CPU PERF: {d:.5} GB/s\n", .{gb / elapsed_s});
    }
}

inline fn matchGpu(io: Io, stdout: *std.Io.Writer, ctx: GpuContext) !void {
    std.debug.assert(ctx.size != 0);
    std.debug.assert(ctx.max_threads != 0);

    const start = if (metrics) std.Io.Clock.awake.now(io) else {};

    hip.pfac(.{
        .warps = if (ctx.size % ctx.max_threads != 0) ctx.size / ctx.max_threads + 1 else ctx.size / ctx.max_threads,
        .threads = if (ctx.size < ctx.max_threads) ctx.size else ctx.max_threads,
        .stream = ctx.stream,
    }, .{
        .prefix_table = @ptrCast(ctx.device_fsm),
        .transition_table = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.device_fsm)) + @sizeOf(@FieldType(FSM, "prefix_table")))),
        .postfix_table = @ptrCast(@alignCast(@as([*]u8, @ptrCast(ctx.device_fsm)) + @sizeOf(@FieldType(FSM, "prefix_table")) + @sizeOf(@FieldType(FSM, "transition_table")))),
        .signatures = ctx.signatures,
    }, .{
        .ptr = @ptrCast(ctx.device_blob),
        .len = ctx.size,
    }, @ptrCast(@alignCast(ctx.device_matches)));

    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe or metrics) {
        try hh.wrapError(hip.hipStreamSynchronize(ctx.stream));
        try hh.wrapError(hip.hipGetLastError());

        if (metrics) {
            const elapsed = start.untilNow(io, .awake);
            const elapsed_ms = @as(f128, @floatFromInt(elapsed.toNanoseconds())) / 1_000_000;
            const elapsed_s = elapsed_ms / 1000;

            const gb = @as(f128, @floatFromInt(ctx.size)) / 1_000_000_000;

            try stdout.print("GPU TIME: {d:.5} ms\n", .{elapsed_ms});
            try stdout.print("GPU PERF: {d:.5} GB/s\n", .{gb / elapsed_s});
        }
    }
}

const base_signatures: []const []const u8 = &[_][]const u8{
    "dolor sit amet, consectetuer adipiscing elit. Aenean commodo ligula",
    "parturient montes, nascetur ridiculus mus. Donec quam felis, ultricies",
    "In enim justo, rhoncus ut, imperdiet a, venenatis vitae, justo. Nullam",
};

pub fn TestHelper(comptime sizes: struct { stdout: usize = 1024, stderr: usize = 1024, stdin: usize = 1024 }) type {
    return struct {
        stdout: Buffered(sizes.stdout, .writer),
        stderr: Buffered(sizes.stderr, .writer),
        stdin: Buffered(sizes.stdin, .reader),

        pub fn Buffered(comptime size: usize, comptime @"type": enum { writer, reader }) type {
            return switch (@"type") {
                .writer => struct {
                    buffer: [size]u8,
                    writer: Io.Writer,
                },
                .reader => struct {
                    buffer: [size]u8,
                    reader: Io.Reader,
                },
            };
        }

        const Self = @This();

        pub fn init(self: *Self) void {
            self.stdin.reader = Io.Reader.fixed(&self.stdin.buffer);
            self.stdout.writer = Io.Writer.fixed(&self.stdout.buffer);
            self.stderr.writer = Io.Writer.fixed(&self.stderr.buffer);
        }
    };
}

pub const TestFile = struct {
    name: [:0]const u8,
    content: []const u8,

    const signatures: TestFile = .{
        .name = "test_signatures.json",
        .content =
        \\[
        ++ "\n    \"" ++ base_signatures[0] ++ "\",\n" ++ "    \"" ++ base_signatures[1] ++ "\",\n" ++ "    \"" ++ base_signatures[2] ++ "\"\n" ++
            \\]
        ,
    };

    const match: TestFile = .{
        .name = "match.txt",
        .content = "Some preamble text. " ++
            base_signatures[0] ++
            " middle text. " ++
            base_signatures[1] ++
            " more text. " ++
            base_signatures[2] ++
            " end.",
    };

    inline fn create(self: *const TestFile, io: Io, cwd: Io.Dir) void {
        comptime std.debug.assert(builtin.is_test);

        const file = cwd.createFile(
            io,
            self.name,
            .{
                .read = true,
                .exclusive = true,
            },
        ) catch @panic("cannot create test file, in the specified directory.");

        defer file.close(io);

        var writer = file.writer(io, &.{});
        writer.interface.writeAll(self.content) catch @panic("cannot write test file contents.");
    }

    inline fn destroy(self: *const TestFile, io: Io, cwd: Io.Dir) void {
        comptime std.debug.assert(builtin.is_test);

        cwd.deleteFile(io, self.name) catch @panic("cannot delete test file.");
    }
};

pub const TestDirectory = struct {
    name: ?[:0]const u8,
    directories: []const TestDirectory,
    files: []const TestFile,

    pub const full: TestDirectory = .{
        .name = null,
        .directories = &.{.{
            .name = "test_targets",
            .directories = &.{},
            .files = &.{
                TestFile.match,
                .{
                    .name = "dummy1.txt",
                    .content = "Nothing matches here, no way!",
                },
                .{
                    .name = "dummy2.txt",
                    .content = "Nothing matches here, no way, really no way!",
                },
            },
        }},
        .files = &.{
            TestFile.signatures,
        },
    };

    pub const only_targets: TestDirectory = .{
        .name = null,
        .directories = &.{.{
            .name = "test_targets",
            .directories = &.{},
            .files = &.{
                TestFile.match,
                .{
                    .name = "dummy1.txt",
                    .content = "Nothing matches here, no way!",
                },
                .{
                    .name = "dummy2.txt",
                    .content = "Nothing matches here, no way, really no way!",
                },
            },
        }},
        .files = &.{},
    };

    pub const only_signatures: TestDirectory = .{
        .name = null,
        .directories = &.{},
        .files = &.{
            TestFile.signatures,
        },
    };

    pub inline fn createTmpDir(self: *const TestDirectory, io: Io) std.testing.TmpDir {
        comptime std.debug.assert(builtin.is_test);
        comptime std.debug.assert(self.name == null);

        const tmp_dir = std.testing.tmpDir(.{ .access_sub_paths = true });

        inline for (self.directories) |directory| {
            comptime std.debug.assert(directory.directories.len == 0);

            tmp_dir.dir.createDir(io, directory.name.?, .default_dir) catch @panic("cannot create sub directory.");
            const dir = tmp_dir.dir.openDir(io, directory.name.?, .{ .access_sub_paths = false }) catch @panic("cannot open created directory.");

            inline for (directory.files) |file| {
                file.create(io, dir);
            }
        }

        inline for (self.files) |file| {
            file.create(io, tmp_dir.dir);
        }

        return tmp_dir;
    }
};

test "Exported fsm binary matches with a build fsm binary" {
    try std.testing.expect(!metrics);

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var helper: TestHelper(.{ .stdout = 170496 }) = undefined;
    helper.init();

    var tmp_dir = TestDirectory.only_signatures.createTmpDir(io);
    defer tmp_dir.cleanup();

    try std.testing.expectEqual(0, try scan(&[_][:0]const u8{
        "--export",
        TestFile.signatures.name,
    }, allocator, io, tmp_dir.dir, &helper.stdin.reader, &helper.stdout.writer, &helper.stderr.writer));

    var fsm = init_fsm: {
        var builder: FSMBuilder = .empty;
        defer builder.deinit(allocator);

        for (base_signatures) |signature| {
            builder.addSignature(allocator, signature) catch |err| switch (err) {
                error.SignatureExists => {},
                else => return err,
            };
        }

        break :init_fsm try builder.buildFSM(io, allocator, &helper.stdout.writer);
    };

    defer fsm.deinit(allocator);

    const prefix_size: usize = @sizeOf(@FieldType(FSM, "prefix_table"));
    const transition_size: usize = @sizeOf(@FieldType(FSM, "transition_table"));

    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&fsm.prefix_table), helper.stdout.buffer[0..prefix_size]);

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&fsm.transition_table),
        helper.stdout.buffer[prefix_size .. prefix_size + transition_size],
    );

    try std.testing.expectEqual(
        fsm.signatures,
        std.mem.bytesToValue(@FieldType(FSM, "signatures"), helper.stdout.buffer[prefix_size + transition_size .. prefix_size + transition_size + @sizeOf(@FieldType(FSM, "signatures"))]),
    );

    try std.testing.expectEqualSlices(
        u8,
        @as([*]const u8, @ptrCast(fsm.postfix_table.ptr))[0 .. @sizeOf(FSM.PostStateType) * FSM.permutations * fsm.postfix_table.len],
        helper.stdout.buffer[prefix_size + transition_size + @sizeOf(@FieldType(FSM, "signatures")) .. helper.stdout.writer.end],
    );
}

inline fn @"scan dummy directory and single file"(comptime device: enum { cpu, gpu }) !void {
    try std.testing.expect(!metrics);

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var helper: TestHelper(.{}) = undefined;
    helper.init();

    var tmp_dir = TestDirectory.full.createTmpDir(io);
    defer tmp_dir.cleanup();

    const base_args: []const [:0]const u8 = &[_][:0]const u8{
        TestFile.signatures.name,
        "--output",
        "c",
    } ++ if (device == .cpu) &[_][:0]const u8{"--cpu"} else &[_][:0]const u8{};

    var test_slices: [2][]const u8 = undefined;

    {
        var start_of_out: usize = 0;
        inline for (.{
            &[_][:0]const u8{ "--recursive", TestDirectory.full.directories[0].name.? },
            &[_][:0]const u8{TestDirectory.full.directories[0].name.? ++ "/" ++ TestDirectory.full.directories[0].files[0].name},
        }, 0..) |args, i| {
            try std.testing.expectEqual(0, try scan(
                base_args ++ args,
                allocator,
                io,
                tmp_dir.dir,
                &helper.stdin.reader,
                &helper.stdout.writer,
                &helper.stderr.writer,
            ));

            test_slices[i] = helper.stdout.buffer[start_of_out..helper.stdout.writer.end];
            start_of_out += helper.stdout.writer.end;
        }
    }

    const single_count = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, test_slices[0], "\n"), 10);
    const recursive_count = try std.fmt.parseInt(usize, std.mem.trimEnd(u8, test_slices[1], "\n"), 10);

    try std.testing.expectEqual(3, single_count);
    try std.testing.expectEqual(3, recursive_count);
}

test "Cpu scan dummy directory and single file" {
    try @"scan dummy directory and single file"(.gpu);
}

test "Gpu scan dummy directory and single file" {
    try @"scan dummy directory and single file"(.cpu);
}

inline fn @"scan blob from stdin"(comptime device: enum { cpu, gpu }) !void {
    try std.testing.expect(!metrics);

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var helper: TestHelper(.{}) = undefined;
    helper.init();

    @memcpy(helper.stdin.buffer[0..TestFile.match.content.len], TestFile.match.content);
    helper.stdin.reader.end = TestFile.match.content.len;

    var tmp_dir = TestDirectory.only_signatures.createTmpDir(io);
    defer tmp_dir.cleanup();

    try std.testing.expectEqual(0, try scan(
        &[_][:0]const u8{
            "--output",
            "c",
            "--stdin",
            "blob",
            TestFile.signatures.name,
        } ++ if (device == .cpu) &[_][:0]const u8{"--cpu"} else &[_][:0]const u8{},
        allocator,
        io,
        tmp_dir.dir,
        &helper.stdin.reader,
        &helper.stdout.writer,
        &helper.stderr.writer,
    ));

    try std.testing.expectEqual(3, std.fmt.parseInt(usize, std.mem.trimEnd(u8, helper.stdout.buffer[0..helper.stdout.writer.end], "\n"), 10));
}

test "Gpu scan blob from stdin" {
    try @"scan blob from stdin"(.gpu);
}

test "Cpu scan blob from stdin" {
    try @"scan blob from stdin"(.cpu);
}

inline fn @"scan, singnatures from stdin"(comptime device: enum { cpu, gpu }) !void {
    try std.testing.expect(!metrics);

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var helper: TestHelper(.{}) = undefined;
    helper.init();

    @memcpy(helper.stdin.buffer[0..TestFile.signatures.content.len], TestFile.signatures.content);
    helper.stdin.reader.end = TestFile.signatures.content.len;

    var tmp_dir = TestDirectory.only_targets.createTmpDir(io);
    defer tmp_dir.cleanup();

    try std.testing.expectEqual(0, try scan(
        &[_][:0]const u8{
            "--output",
            "c",
            "--stdin",
            "s",
            "-r",
            TestDirectory.full.directories[0].name.? ++ "/" ++ TestDirectory.full.directories[0].files[0].name,
        } ++ if (device == .cpu) &[_][:0]const u8{"--cpu"} else &[_][:0]const u8{},
        allocator,
        io,
        tmp_dir.dir,
        &helper.stdin.reader,
        &helper.stdout.writer,
        &helper.stderr.writer,
    ));

    try std.testing.expectEqual(3, std.fmt.parseInt(usize, std.mem.trimEnd(u8, helper.stdout.buffer[0..helper.stdout.writer.end], "\n"), 10));
}

test "Gpu scan, singnatures from stdin" {
    try @"scan, singnatures from stdin"(.gpu);
}

test "Cpu scan, singnatures from stdin" {
    try @"scan, singnatures from stdin"(.cpu);
}

inline fn @"scan, fsm from stdin"(comptime device: enum { cpu, gpu }) !void {
    try std.testing.expect(!metrics);

    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var helper: TestHelper(.{ .stdin = 170496 }) = undefined;
    helper.init();

    var tmp_dir = TestDirectory.only_targets.createTmpDir(io);
    defer tmp_dir.cleanup();

    var fsm = init_fsm: {
        var builder: FSMBuilder = .empty;
        defer builder.deinit(allocator);

        for (base_signatures) |signature| {
            builder.addSignature(allocator, signature) catch |err| switch (err) {
                error.SignatureExists => {},
                else => return err,
            };
        }

        break :init_fsm try builder.buildFSM(io, allocator, &helper.stdout.writer);
    };

    defer fsm.deinit(allocator);

    const prefix_size: usize = @sizeOf(@FieldType(FSM, "prefix_table"));
    const transition_size: usize = @sizeOf(@FieldType(FSM, "transition_table"));
    var start: usize = 0;
    @memcpy(helper.stdin.buffer[start .. start + prefix_size], std.mem.asBytes(&fsm.prefix_table));
    start += prefix_size;
    @memcpy(helper.stdin.buffer[start .. start + transition_size], std.mem.asBytes(&fsm.transition_table));
    start += transition_size;
    @memcpy(helper.stdin.buffer[start .. start + @sizeOf(@FieldType(FSM, "signatures"))], std.mem.asBytes(&fsm.signatures));
    start += @sizeOf(@FieldType(FSM, "signatures"));
    @memcpy(
        helper.stdin.buffer[start .. start + @sizeOf(FSM.PostStateType) * FSM.permutations * fsm.postfix_table.len],
        @as([*]const u8, @ptrCast(fsm.postfix_table.ptr))[0 .. @sizeOf(FSM.PostStateType) * FSM.permutations * fsm.postfix_table.len],
    );
    start += @sizeOf(FSM.PostStateType) * FSM.permutations * fsm.postfix_table.len;

    helper.stdin.reader.end = start;

    try std.testing.expectEqual(0, try scan(
        &[_][:0]const u8{
            "--output",
            "c",
            "--stdin",
            "f",
            "-r",
            TestDirectory.only_targets.directories[0].name.? ++ "/" ++ TestDirectory.only_targets.directories[0].files[0].name,
        } ++ if (device == .cpu) &[_][:0]const u8{"--cpu"} else &[_][:0]const u8{},
        allocator,
        io,
        tmp_dir.dir,
        &helper.stdin.reader,
        &helper.stdout.writer,
        &helper.stderr.writer,
    ));

    try std.testing.expectEqual(3, std.fmt.parseInt(usize, std.mem.trimEnd(u8, helper.stdout.buffer[0..helper.stdout.writer.end], "\n"), 10));
}

test "Gpu scan, fsm from stdin" {
    try @"scan, fsm from stdin"(.gpu);
}

test "cpu scan, fsm from stdin" {
    try @"scan, fsm from stdin"(.cpu);
}
