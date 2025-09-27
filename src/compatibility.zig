const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");

const Regex = root.Regex;
const RegexError = root.RegexError;

/// Compatibility testing framework for PCRE/RE2 test suites
pub const CompatibilityTester = struct {
    allocator: Allocator,
    stats: TestStats,
    config: TestConfig,

    const TestStats = struct {
        total_tests: usize = 0,
        passed_tests: usize = 0,
        failed_tests: usize = 0,
        skipped_tests: usize = 0,
        unsupported_features: usize = 0,
        compilation_errors: usize = 0,
        runtime_errors: usize = 0,
        match_mismatches: usize = 0,
    };

    const TestConfig = struct {
        skip_unsupported: bool = true,
        verbose_output: bool = false,
        stop_on_error: bool = false,
        pattern_timeout_ms: u64 = 1000,
    };

    const TestCase = struct {
        pattern: []const u8,
        input: []const u8,
        expected_match: bool,
        expected_groups: ?[]const []const u8 = null,
        flags: []const u8 = "",
        description: []const u8 = "",
    };

    const TestResult = enum {
        pass,
        fail,
        skip,
        unsupported,
        timeout,
        error_compile,
        error_runtime,
    };

    pub fn init(allocator: Allocator, config: TestConfig) CompatibilityTester {
        return CompatibilityTester{
            .allocator = allocator,
            .stats = .{},
            .config = config,
        };
    }

    pub fn runTestCase(self: *CompatibilityTester, test_case: TestCase) !TestResult {
        self.stats.total_tests += 1;

        if (self.config.verbose_output) {
            std.debug.print("Testing: {s} against '{s}'\n", .{ test_case.pattern, test_case.input });
        }

        // Check for unsupported features
        if (self.hasUnsupportedFeatures(test_case.pattern, test_case.flags)) {
            if (self.config.skip_unsupported) {
                self.stats.skipped_tests += 1;
                self.stats.unsupported_features += 1;
                return .unsupported;
            }
        }

        // Compile pattern
        var regex = Regex.compile(self.allocator, test_case.pattern) catch |err| {
            self.stats.failed_tests += 1;
            self.stats.compilation_errors += 1;
            if (self.config.verbose_output) {
                std.debug.print("  Compilation failed: {}\n", .{err});
            }
            return .error_compile;
        };
        defer regex.deinit();

        // Test matching
        const match_result = regex.find(test_case.input) catch |err| {
            self.stats.failed_tests += 1;
            self.stats.runtime_errors += 1;
            if (self.config.verbose_output) {
                std.debug.print("  Runtime error: {}\n", .{err});
            }
            return .error_runtime;
        };

        // Check if match result matches expectation
        const actual_match = match_result != null;
        if (actual_match != test_case.expected_match) {
            self.stats.failed_tests += 1;
            self.stats.match_mismatches += 1;
            if (self.config.verbose_output) {
                std.debug.print("  Match mismatch: expected {}, got {}\n", .{ test_case.expected_match, actual_match });
            }
            return .fail;
        }

        // TODO: Check capture groups if provided
        if (test_case.expected_groups) |expected_groups| {
            if (match_result) |match| {
                if (match.groups) |groups| {
                    for (expected_groups, 0..) |expected_group, i| {
                        if (i < groups.len) {
                            if (groups[i]) |group| {
                                const actual_group = group.slice(test_case.input);
                                if (!std.mem.eql(u8, actual_group, expected_group)) {
                                    self.stats.failed_tests += 1;
                                    if (self.config.verbose_output) {
                                        std.debug.print("  Group {} mismatch: expected '{s}', got '{s}'\n", .{ i, expected_group, actual_group });
                                    }
                                    return .fail;
                                }
                            } else {
                                self.stats.failed_tests += 1;
                                if (self.config.verbose_output) {
                                    std.debug.print("  Group {} missing\n", .{i});
                                }
                                return .fail;
                            }
                        }
                    }
                }
            }
        }

        self.stats.passed_tests += 1;
        if (self.config.verbose_output) {
            std.debug.print("  PASS\n");
        }
        return .pass;
    }

    fn hasUnsupportedFeatures(self: *CompatibilityTester, pattern: []const u8, flags: []const u8) bool {
        _ = self;

        // Check for unsupported pattern features
        if (std.mem.indexOf(u8, pattern, "(?=")) |_| return true;  // Positive lookahead
        if (std.mem.indexOf(u8, pattern, "(?!")) |_| return true;  // Negative lookahead
        if (std.mem.indexOf(u8, pattern, "(?<=")) |_| return true; // Positive lookbehind
        if (std.mem.indexOf(u8, pattern, "(?<!")) |_| return true; // Negative lookbehind
        if (std.mem.indexOf(u8, pattern, "\\1")) |_| return true;   // Backreferences
        if (std.mem.indexOf(u8, pattern, "\\2")) |_| return true;   // Backreferences
        if (std.mem.indexOf(u8, pattern, "(?R)")) |_| return true;  // Recursion
        if (std.mem.indexOf(u8, pattern, "(?(")) |_| return true;   // Conditionals
        if (std.mem.indexOf(u8, pattern, "++")) |_| return true;    // Possessive quantifiers
        if (std.mem.indexOf(u8, pattern, "*+")) |_| return true;    // Possessive quantifiers

        // Check for unsupported flags
        if (std.mem.indexOf(u8, flags, "i")) |_| return true;  // Case insensitive (partial support)
        if (std.mem.indexOf(u8, flags, "m")) |_| return true;  // Multiline mode
        if (std.mem.indexOf(u8, flags, "s")) |_| return true;  // Single line mode
        if (std.mem.indexOf(u8, flags, "x")) |_| return true;  // Extended syntax

        return false;
    }

    pub fn loadPCRETestSuite(self: *CompatibilityTester, file_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();

        var line_buffer: [1024]u8 = undefined;
        while (try in_stream.readUntilDelimiterOrEof(line_buffer[0..], '\n')) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip comments and empty lines
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Parse PCRE test format: /pattern/flags input expected_result
            if (self.parsePCRETestLine(trimmed)) |test_case| {
                _ = try self.runTestCase(test_case);
            }
        }
    }

    fn parsePCRETestLine(self: *CompatibilityTester, line: []const u8) ?TestCase {
        _ = self;

        // Very basic PCRE test line parser
        // Real implementation would need to handle escaped delimiters, etc.
        if (line.len < 3 or line[0] != '/') return null;

        // Find end of pattern
        var i: usize = 1;
        while (i < line.len and line[i] != '/') {
            i += 1;
        }
        if (i >= line.len) return null;

        const pattern = line[1..i];
        i += 1; // Skip closing /

        // Extract flags
        const flags_start = i;
        while (i < line.len and line[i] != ' ') {
            i += 1;
        }
        const flags = line[flags_start..i];

        // Skip whitespace
        while (i < line.len and line[i] == ' ') {
            i += 1;
        }

        // Extract input (rest of line for now)
        if (i >= line.len) return null;
        const input = line[i..];

        return TestCase{
            .pattern = pattern,
            .input = input,
            .expected_match = true, // Simplified - real parser would extract this
            .flags = flags,
        };
    }

    pub fn generateBuiltinTestSuite(self: *CompatibilityTester) !void {
        const test_cases = [_]TestCase{
            // Basic literal tests
            .{ .pattern = "hello", .input = "hello world", .expected_match = true },
            .{ .pattern = "hello", .input = "goodbye", .expected_match = false },

            // Character classes
            .{ .pattern = "[a-z]+", .input = "hello", .expected_match = true },
            .{ .pattern = "[0-9]+", .input = "123", .expected_match = true },
            .{ .pattern = "[A-Z]+", .input = "hello", .expected_match = false },

            // Quantifiers
            .{ .pattern = "a+", .input = "aaa", .expected_match = true },
            .{ .pattern = "a*", .input = "bbb", .expected_match = true },
            .{ .pattern = "a?", .input = "b", .expected_match = true },
            .{ .pattern = "a{3}", .input = "aaa", .expected_match = true },
            .{ .pattern = "a{3}", .input = "aa", .expected_match = false },

            // Anchors
            .{ .pattern = "^hello", .input = "hello world", .expected_match = true },
            .{ .pattern = "^hello", .input = "say hello", .expected_match = false },
            .{ .pattern = "world$", .input = "hello world", .expected_match = true },
            .{ .pattern = "world$", .input = "world peace", .expected_match = false },

            // Alternation
            .{ .pattern = "cat|dog", .input = "I have a cat", .expected_match = true },
            .{ .pattern = "cat|dog", .input = "I have a bird", .expected_match = false },

            // Groups
            .{ .pattern = "(hello) (world)", .input = "hello world", .expected_match = true },

            // Escape sequences
            .{ .pattern = "\\d+", .input = "123", .expected_match = true },
            .{ .pattern = "\\w+", .input = "hello", .expected_match = true },
            .{ .pattern = "\\s+", .input = "   ", .expected_match = true },

            // Unicode properties (basic)
            .{ .pattern = "\\p{L}+", .input = "hello", .expected_match = true },
            .{ .pattern = "\\p{N}+", .input = "123", .expected_match = true },

            // Any character
            .{ .pattern = ".", .input = "a", .expected_match = true },
            .{ .pattern = ".", .input = "\n", .expected_match = false },
            .{ .pattern = "...", .input = "abc", .expected_match = true },

            // Edge cases
            .{ .pattern = "", .input = "", .expected_match = true },
            .{ .pattern = "a", .input = "", .expected_match = false },
        };

        for (test_cases) |test_case| {
            _ = try self.runTestCase(test_case);
        }
    }

    pub fn printReport(self: *const CompatibilityTester) void {
        const stats = &self.stats;

        std.debug.print("\n" ++ "=" ** 50 ++ "\n");
        std.debug.print("COMPATIBILITY TEST REPORT\n");
        std.debug.print("=" ** 50 ++ "\n");
        std.debug.print("Total tests: {}\n", .{stats.total_tests});
        std.debug.print("Passed: {} ({d:.1}%)\n", .{ stats.passed_tests, @as(f64, @floatFromInt(stats.passed_tests)) * 100.0 / @as(f64, @floatFromInt(stats.total_tests)) });
        std.debug.print("Failed: {} ({d:.1}%)\n", .{ stats.failed_tests, @as(f64, @floatFromInt(stats.failed_tests)) * 100.0 / @as(f64, @floatFromInt(stats.total_tests)) });
        std.debug.print("Skipped: {} ({d:.1}%)\n", .{ stats.skipped_tests, @as(f64, @floatFromInt(stats.skipped_tests)) * 100.0 / @as(f64, @floatFromInt(stats.total_tests)) });

        std.debug.print("\nFailure breakdown:\n");
        std.debug.print("  Unsupported features: {}\n", .{stats.unsupported_features});
        std.debug.print("  Compilation errors: {}\n", .{stats.compilation_errors});
        std.debug.print("  Runtime errors: {}\n", .{stats.runtime_errors});
        std.debug.print("  Match mismatches: {}\n", .{stats.match_mismatches});

        if (stats.total_tests > 0) {
            const pass_rate = @as(f64, @floatFromInt(stats.passed_tests)) * 100.0 / @as(f64, @floatFromInt(stats.total_tests));
            if (pass_rate >= 90.0) {
                std.debug.print("\n✓ EXCELLENT: {d:.1}% pass rate achieved!\n", .{pass_rate});
            } else if (pass_rate >= 75.0) {
                std.debug.print("\n✓ GOOD: {d:.1}% pass rate\n", .{pass_rate});
            } else if (pass_rate >= 50.0) {
                std.debug.print("\n⚠ FAIR: {d:.1}% pass rate\n", .{pass_rate});
            } else {
                std.debug.print("\n✗ POOR: {d:.1}% pass rate - significant work needed\n", .{pass_rate});
            }
        }
    }

    pub fn getPassRate(self: *const CompatibilityTester) f64 {
        if (self.stats.total_tests == 0) return 0.0;
        return @as(f64, @floatFromInt(self.stats.passed_tests)) * 100.0 / @as(f64, @floatFromInt(self.stats.total_tests));
    }
};

test "compatibility tester basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tester = CompatibilityTester.init(allocator, .{});

    const test_case = CompatibilityTester.TestCase{
        .pattern = "hello",
        .input = "hello world",
        .expected_match = true,
    };

    const result = try tester.runTestCase(test_case);
    try std.testing.expect(result == .pass);
}

test "compatibility tester builtin suite" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tester = CompatibilityTester.init(allocator, .{ .verbose_output = false });
    try tester.generateBuiltinTestSuite();

    const pass_rate = tester.getPassRate();
    try std.testing.expect(pass_rate > 80.0); // Should pass most basic tests
}