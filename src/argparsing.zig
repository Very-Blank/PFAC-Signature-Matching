const std = @import("std");

const capacity_default: usize = 10;
const output_default: OutputType = .Both;

const usage_no_stdin_msg = "    usage: scan [OPTIONS] <signatures.json> [paths...]\n";
const usage_stdin_msg = "   usage: scan [OPTIONS] --stdin <s|f> [paths...]\n";
const usage_stdin_blob_msg = "  usage: scan [OPTIONS] --stdin <b> <signatures.json>\n";
const usage_export_msg = "  usage: scan [OPTIONS] --export <signatures.json>\n";

const missing_option_fmt: []const u8 = "error: ({s}) argument expected an option {s}.\n";
const parse_option_error_fmt: []const u8 = "error: failed to parse ({s}) option value {s}.\n";
const set_option_mult_fmt: []const u8 = "error: ({s}) option set multiple times.\n";
const fighting_options_fmt: []const u8 = "error: ({s}) doesn't allow option {s}.\n";

const missing_signatures_msg: []const u8 = "error: missing <singatures.json> argument\n";
const missing_paths_msg: []const u8 = "error: missing [paths...] argument\n";

const help_msg =
    \\usage: scan [OPTIONS] <signatures.json> [paths...]
    \\       scan [OPTIONS] --stdin <b> <signatures.json> 
    \\       scan [OPTIONS] --stdin <s|f> [paths...]
    \\
    \\arguments:
    \\  <signatures.json>       Path to the signatures file
    \\  [paths...]              Files or directories to scan
    \\
    \\options:
    \\  -i, --stdin <type>      Read from stdin instead of a file
    \\                              s, signatures  - read signatures from stdin
    \\                              b, blob        - read scan target from stdin
    \\                              f, fsm         - read compiled FSM from stdin
    \\                              Note: in s and f mode the signature map isn't available;
    \\                              output will only have the singature id and not whole value
    \\
    \\  -e, --export            Compile signatures to FSM and output it to the stdout
    \\                              Note: cannot be combined with scanning, use separately to
    \\                              pre-compile signatures before scanning
    \\
    \\  -o, --output <type>     Output format (default: both)
    \\                              l, list   - list matched signatures
    \\                              c, count  - match count
    \\                              b, both   - list and count
    \\
    \\  -c, --capacity <num>    GPU list capacity (default: 10)
    \\
    \\  -r, --recursive         Scan directories recursively
    \\
    \\      --warm-up           Run a GPU warm up, will give more accurate performance metrics.
    \\
    \\      --cpu               Run on the CPU instead of the GPU
    \\
    \\  -h, --help              Print this help message
    \\
;

const OptionType = enum {
    Stdin,
    Export,
    Recursive,
    Capacity,
    Output,
    Help,
    WarmUp,
    Cpu,

    const Self = @This();

    pub fn parse(arg: [:0]const u8) !Self {
        std.debug.assert(arg[0] == '-');

        if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--stdin")) return .Stdin;
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--export")) return .Export;
        if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--recursive")) return .Recursive;
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) return .Output;
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return .Help;
        if (std.mem.eql(u8, arg, "--capacity")) return .Capacity;
        if (std.mem.eql(u8, arg, "--warm-up")) return .WarmUp;
        if (std.mem.eql(u8, arg, "--cpu")) return .Cpu;

        return error.InvalidArgument;
    }
};

const StdinType = enum {
    Blob,
    Signatures,
    FSM,

    const Self = @This();

    pub fn parse(option: [:0]const u8) !Self {
        if (std.mem.eql(u8, option, "b") or std.mem.eql(u8, option, "blob")) return .Blob;
        if (std.mem.eql(u8, option, "s") or std.mem.eql(u8, option, "signatures")) return .Signatures;
        if (std.mem.eql(u8, option, "f") or std.mem.eql(u8, option, "fsm")) return .FSM;

        return error.InvalidOption;
    }
};

const OutputType = enum {
    List,
    Count,
    Both,

    const Self = @This();

    pub fn parse(option: [:0]const u8) !Self {
        if (std.mem.eql(u8, option, "l") or std.mem.eql(u8, option, "list")) return .List;
        if (std.mem.eql(u8, option, "c") or std.mem.eql(u8, option, "count")) return .Count;
        if (std.mem.eql(u8, option, "b") or std.mem.eql(u8, option, "both")) return .Both;

        return error.InvalidOption;
    }
};

const FSMSource = union(enum) {
    singatures: SignaturesSource,
    stdin: void,
};

const SignaturesSource = union(enum) {
    path: [:0]const u8,
    stdin: void,
};

const BlobSource = union(enum) {
    paths: struct {
        source: [][:0]const u8,
        recursive: bool,
    },
    stdin: void,
};

const Mode = union(enum) {
    scan: struct {
        sources: BlobSource,
        output: OutputType,
        capacity: usize,
        device: union(enum) {
            cpu: void,
            gpu: struct {
                warm_up: bool,
            },
        },
    },

    @"export": void,
};

/// Parses args to more readable form, ensures that only only source uses stdin.
pub fn parseArgs(
    args: []const [:0]const u8,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !struct {
    fsm_source: FSMSource,
    mode: Mode,
} {
    var stdin: ?StdinType = null;
    var output: ?OutputType = null;
    var recursive: bool = false;
    var cpu: bool = false;
    var warm_up: bool = false;

    var @"export": bool = false;

    var capacity: ?usize = null;

    var paths: std.ArrayList([:0]const u8) = .empty;
    defer paths.deinit(allocator);

    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg: [:0]const u8 = args[i];
            const option: ?[:0]const u8 = if (args.len <= i + 1 or args[i + 1][0] == '-') null else args[i + 1];

            if (arg[0] == '-') {
                switch (OptionType.parse(arg) catch |err| {
                    try stderr.print("error: invalid argument {s}.\n", .{arg});
                    return err;
                }) {
                    .Stdin => {
                        if (stdin != null) {
                            try stderr.print(set_option_mult_fmt, .{"-i, --stdin"});
                            return error.InvalidArguments;
                        }

                        if (option) |capture| {
                            stdin = StdinType.parse(capture) catch {
                                try stderr.print(parse_option_error_fmt, .{ "-i, --stdin", capture });
                                return error.InvalidArguments;
                            };
                        } else {
                            try stderr.print(missing_option_fmt, .{ "-i, --stdin", "<s|b|f>, <signature|blob|fsm>" });
                            return error.InvalidArguments;
                        }

                        i += 1;
                    },
                    .Capacity => {
                        if (option) |capture| {
                            capacity = std.fmt.parseInt(usize, capture, 10) catch {
                                try stderr.print(parse_option_error_fmt, .{ "-c, --capacity", capture });
                                return error.InvalidArguments;
                            };
                        } else {
                            try stderr.print(missing_option_fmt, .{ "-c, --capacity", "<num>" });
                            return error.InvalidArguments;
                        }

                        i += 1;
                    },
                    .Output => {
                        if (output != null) {
                            try stderr.print(set_option_mult_fmt, .{"-o, --output"});
                            return error.InvalidArguments;
                        }

                        if (option) |capture| {
                            output = OutputType.parse(capture) catch {
                                try stderr.print(parse_option_error_fmt, .{ "-o, --output", capture });
                                return error.InvalidArguments;
                            };
                        } else {
                            try stderr.print(missing_option_fmt, .{ "-o, --output", "<l|n|b>, <list|count|both>" });
                            return error.InvalidArguments;
                        }

                        i += 1;
                    },
                    .Export => @"export" = true,
                    .Recursive => recursive = true,
                    .WarmUp => warm_up = true,
                    .Cpu => cpu = true,
                    .Help => {
                        try stdout.print(help_msg, .{});
                        return error.Help;
                    },
                }

                continue;
            }

            try paths.append(allocator, arg);
        }
    }

    if (@"export") {
        if (stdin) |stdin_capture| return switch (stdin_capture) {
            .Blob, .FSM => |value| {
                try stderr.print(fighting_options_fmt, .{ "-e, --export", switch (value) {
                    .Blob => "-i b, --stdin b",
                    .FSM => "-i f, --stdin f",
                    else => unreachable,
                } });
                return error.InvalidArguments;
            },
            .Signatures => .{
                .fsm_source = .{ .singatures = .{ .stdin = {} } },
                .mode = .{ .@"export" = {} },
            },
        };

        if (paths.items.len == 0) {
            try stderr.print(missing_signatures_msg ++ usage_no_stdin_msg, .{});
            return error.InvalidArguments;
        }

        if (1 < paths.items.len) {
            try stderr.print("error: (-e, --export) doesn't allow scan targets.\n" ++ usage_export_msg, .{});
            try stderr.print("\nremoving these arguments will resolve the error:\n", .{});
            for (paths.items[1..paths.items.len]) |path| {
                try stderr.print("  {s}\n", .{path});
            }

            return error.InvalidArguments;
        }

        const msgs = .{ "-o, --output", "-r, --recursive", "--capacity", "--cpu", "--warm-up" };
        inline for (.{ output, recursive, capacity, cpu, warm_up }, 0..) |value, i| {
            switch (@typeInfo(@TypeOf(value))) {
                .optional => {
                    if (value != null) {
                        try stderr.print(fighting_options_fmt, .{ "-e, --export", msgs[i] });
                        return error.InvalidArguments;
                    }
                },
                .bool => {
                    if (value) {
                        try stderr.print(fighting_options_fmt, .{ "-e, --export", msgs[i] });
                        return error.InvalidArguments;
                    }
                },
                else => @compileError("Unexpected type"),
            }
        }

        return .{
            .fsm_source = .{ .singatures = .{ .path = paths.items[0] } },
            .mode = .{ .@"export" = {} },
        };
    }

    if (paths.items.len == 0) {
        try stderr.print("error: missing <singatures.json> argument.\n" ++ usage_no_stdin_msg, .{});
        return error.InvalidArguments;
    }

    if (cpu and warm_up) {
        try stderr.print(fighting_options_fmt, .{ "--cpu", "--warm-up" });
        return error.InvalidArguments;
    }

    return .{
        .fsm_source = init_source: {
            if (stdin) |stdin_capture| switch (stdin_capture) {
                .Blob => {
                    if (1 < paths.items.len) {
                        try stderr.print(fighting_options_fmt ++ usage_stdin_blob_msg, .{ "-i b, --stdin b", "[paths...]" });
                        return error.InvalidArguments;
                    }

                    if (recursive) {
                        try stderr.print(fighting_options_fmt ++ usage_stdin_blob_msg, .{ "-i b, --stdin b", "-r, --recursive" });
                        return error.InvalidArguments;
                    }
                },
                .FSM => {
                    break :init_source .{
                        .stdin = {},
                    };
                },
                .Signatures => {
                    break :init_source .{ .singatures = .{ .stdin = {} } };
                },
            };

            break :init_source .{
                .singatures = .{ .path = paths.orderedRemove(0) },
            };
        },
        .mode = .{
            .scan = .{
                .sources = init_scan_source: {
                    if (stdin) |stdin_capture| switch (stdin_capture) {
                        .Blob => break :init_scan_source .{
                            .stdin = {},
                        },
                        else => {},
                    };

                    break :init_scan_source .{ .paths = .{
                        .source = try paths.toOwnedSlice(allocator),
                        .recursive = recursive,
                    } };
                },
                .output = if (output) |capture| capture else output_default,
                .capacity = if (capacity) |capture| capture else capacity_default,
                .device = if (cpu) .{
                    .cpu = {},
                } else .{ .gpu = .{
                    .warm_up = warm_up,
                } },
            },
        },
    };
}
