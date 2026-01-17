const std = @import("std");
const print = std.debug.print;
const zregex = @import("zregex");

const CliOptions = struct {
    verbose: bool = false,
    quiet: bool = false,
    timing: bool = false,
    groups_only: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) {
        try printVersion();
        return;
    }

    if (std.mem.eql(u8, args[1], "--features") or std.mem.eql(u8, args[1], "-f")) {
        try printFeatures();
        return;
    }

    if (std.mem.eql(u8, args[1], "--interactive") or std.mem.eql(u8, args[1], "-i")) {
        try runInteractiveMode(allocator);
        return;
    }

    // Parse command line options and pattern matching
    var options = CliOptions{};
    var pattern_arg_index: usize = 1;

    // Parse options
    var arg_i: usize = 1;
    while (arg_i < args.len) {
        const arg = args[arg_i];
        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-V")) {
                options.verbose = true;
            } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
                options.quiet = true;
            } else if (std.mem.eql(u8, arg, "--timing") or std.mem.eql(u8, arg, "-t")) {
                options.timing = true;
            } else if (std.mem.eql(u8, arg, "--groups-only") or std.mem.eql(u8, arg, "-g")) {
                options.groups_only = true;
            } else {
                std.debug.print("Error: Unknown option '{s}'\n\n", .{arg});
                try printUsage();
                return;
            }
            arg_i += 1;
        } else {
            pattern_arg_index = arg_i;
            break;
        }
    }

    // Check we have pattern and input
    if (pattern_arg_index >= args.len or pattern_arg_index + 1 >= args.len) {
        std.debug.print("Error: Pattern and input text required\n\n", .{});
        try printUsage();
        return;
    }

    const pattern = args[pattern_arg_index];
    const input_text = args[pattern_arg_index + 1];

    try runMatch(allocator, pattern, input_text, options);
}

fn printUsage() !void {
    const usage =
        \\Usage: zregex [OPTIONS] <pattern> <input>
        \\       zregex --interactive
        \\
        \\Options:
        \\  -h, --help        Show this help message
        \\  -v, --version     Show version information
        \\  -f, --features    Show compiled features
        \\  -i, --interactive Start interactive mode
        \\  -V, --verbose     Show detailed matching information
        \\  -q, --quiet       Only show match results (no extra output)
        \\  -t, --timing      Show performance timing information
        \\  -g, --groups-only Show only capture groups (if matched)
        \\
        \\Examples:
        \\  zregex "hello" "hello world"
        \\  zregex --verbose "(\\w+)" "test string"
        \\  zregex --timing "[0-9]+" "test 123"
        \\  zregex --groups-only "(\\w+)@(\\w+)" "user@domain"
        \\  zregex --interactive
        \\
    ;
    print("{s}", .{usage});
}

fn printVersion() !void {
    const version =
        \\zregex 0.1.0-alpha
        \\A Zig regular expression library
        \\
    ;
    print("{s}", .{version});
}

fn printFeatures() !void {
    const info = zregex.features.getFeatureInfo();

    print("Build-time features:\n", .{});
    print("  JIT: {}\n", .{info.build_time.jit});
    print("  Unicode: {}\n", .{info.build_time.unicode});
    print("  Streaming: {}\n", .{info.build_time.streaming});
    print("  Capture Groups: {}\n", .{info.build_time.capture_groups});
    print("  Backtracking: {}\n", .{info.build_time.backtracking});

    print("\nRuntime settings:\n", .{});
    print("  Prefer JIT: {}\n", .{info.runtime.prefer_jit});
    print("  Prefer Streaming: {}\n", .{info.runtime.prefer_streaming});
    print("  Force NFA: {}\n", .{info.runtime.force_nfa});
    print("  Diagnostics: {}\n", .{info.runtime.enable_diagnostics});
    print("  Debug Mode: {}\n", .{info.runtime.debug_mode});

    print("\nEffective features:\n", .{});
    print("  JIT Enabled: {}\n", .{info.effective.jit_enabled});
    print("  Streaming Preferred: {}\n", .{info.effective.streaming_preferred});
    print("  Diagnostics Enabled: {}\n", .{info.effective.diagnostics_enabled});
    print("  Debug Mode: {}\n", .{info.effective.debug_mode});
}

fn runMatch(allocator: std.mem.Allocator, pattern: []const u8, input_text: []const u8, options: CliOptions) !void {
    // Timing setup using std.time.Timer (Zig 0.16.0-dev compatible)
    var timer: ?std.time.Timer = null;
    var compile_time_ns: u64 = 0;
    var match_time_ns: u64 = 0;

    if (options.timing) {
        timer = std.time.Timer.start() catch null;
    }

    if (options.verbose and !options.quiet) {
        std.debug.print("Compiling pattern: '{s}'\n", .{pattern});
    }

    var regex = zregex.Regex.compile(allocator, pattern) catch |err| {
        switch (err) {
            zregex.RegexError.InvalidPattern => {
                if (!options.quiet) {
                    std.debug.print("Error: Invalid pattern '{s}'\n", .{pattern});
                }
                std.process.exit(1);
            },
            zregex.RegexError.OutOfMemory => {
                if (!options.quiet) {
                    std.debug.print("Error: Out of memory compiling pattern\n", .{});
                }
                std.process.exit(2);
            },
            else => {
                if (!options.quiet) {
                    std.debug.print("Error: Failed to compile pattern: {}\n", .{err});
                }
                std.process.exit(3);
            },
        }
    };
    defer regex.deinit();

    if (timer) |*t| {
        compile_time_ns = t.lap();
    }

    if (options.verbose and !options.quiet) {
        std.debug.print("Searching in input: '{s}'\n", .{input_text});
    }

    const found_match = try regex.find(input_text);

    if (timer) |*t| {
        match_time_ns = t.lap();
    }

    if (found_match) |match| {
        var match_copy = match;
        defer match_copy.deinit(allocator);

        if (options.groups_only) {
            // Only show groups if they exist
            if (match_copy.groups) |groups| {
                for (groups, 0..) |group, idx| {
                    if (group) |g| {
                        std.debug.print("Group {}: \"{s}\"\n", .{
                            idx,
                            g.slice(input_text),
                        });
                    }
                }
            }
        } else if (options.quiet) {
            // Just print the match
            std.debug.print("{s}\n", .{match_copy.slice(input_text)});
        } else {
            // Standard output
            std.debug.print("✓ Match found: \"{s}\" at position {}..{}\n", .{
                match_copy.slice(input_text),
                match_copy.start,
                match_copy.end,
            });

            if (match_copy.groups) |groups| {
                if (options.verbose) {
                    std.debug.print("  Capture groups ({}): \n", .{groups.len});
                } else {
                    std.debug.print("  Groups:\n", .{});
                }
                for (groups, 0..) |group, idx| {
                    if (group) |g| {
                        if (options.verbose) {
                            std.debug.print("    [{}] \"{s}\" at position {}..{}\n", .{
                                idx,
                                g.slice(input_text),
                                g.start,
                                g.end,
                            });
                        } else {
                            std.debug.print("    Group {}: \"{s}\"\n", .{
                                idx,
                                g.slice(input_text),
                            });
                        }
                    } else if (options.verbose) {
                        std.debug.print("    [{}] (no match)\n", .{idx});
                    }
                }
            } else if (options.verbose) {
                std.debug.print("  No capture groups\n", .{});
            }
        }

        if (options.timing and !options.quiet) {
            const compile_time = @as(f64, @floatFromInt(compile_time_ns)) / 1_000_000.0;
            const match_time = @as(f64, @floatFromInt(match_time_ns)) / 1_000_000.0;
            std.debug.print("  Timing: compile={d:.2}ms, match={d:.2}ms\n", .{ compile_time, match_time });
        }

        std.process.exit(0);
    } else {
        if (!options.quiet) {
            if (options.verbose) {
                std.debug.print("✗ No match found for pattern '{s}' in input '{s}'\n", .{ pattern, input_text });
            } else {
                std.debug.print("✗ No match found\n", .{});
            }
        }

        if (options.timing and !options.quiet) {
            const compile_time = @as(f64, @floatFromInt(compile_time_ns)) / 1_000_000.0;
            const match_time = @as(f64, @floatFromInt(match_time_ns)) / 1_000_000.0;
            std.debug.print("  Timing: compile={d:.2}ms, match={d:.2}ms\n", .{ compile_time, match_time });
        }

        std.process.exit(1);
    }
}

fn runInteractiveMode(allocator: std.mem.Allocator) !void {
    _ = allocator;
    print("zregex interactive mode - type 'help' for commands\n", .{});
    print("Note: Interactive mode requires manual input. Use command line mode instead.\n", .{});
    print("Example: zregex \"hello\" \"hello world\"\n", .{});

    // For now, just show example usage instead of implementing full interactive mode
    // since std.io access varies between Zig versions
    try printInteractiveHelp();
}

fn printInteractiveHelp() !void {
    const help =
        \\Interactive Commands:
        \\  <pattern> <text>  - Test pattern against text
        \\  help              - Show this help
        \\  features          - Show feature information
        \\  quit, exit        - Exit interactive mode
        \\
        \\Examples:
        \\  hello hello world
        \\  (\\w+) test string
        \\  [0-9]+ the number is 42
        \\
    ;
    print("{s}", .{help});
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
