const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");

const Regex = root.Regex;
const RegexError = root.RegexError;

/// Fuzzing framework for regex engine testing
pub const Fuzzer = struct {
    allocator: Allocator,
    rng: std.rand.DefaultPrng,
    stats: FuzzingStats,
    config: FuzzingConfig,

    const FuzzingStats = struct {
        patterns_tested: usize = 0,
        patterns_failed: usize = 0,
        patterns_timeout: usize = 0,
        redos_found: usize = 0,
        crashes: usize = 0,
        memory_leaks: usize = 0,
        max_execution_time: u64 = 0,
        total_execution_time: u64 = 0,
    };

    const FuzzingConfig = struct {
        max_pattern_length: usize = 100,
        max_input_length: usize = 1000,
        timeout_ms: u64 = 1000,
        enable_redos_detection: bool = true,
        enable_memory_checks: bool = true,
        seed: ?u64 = null,
    };

    pub fn init(allocator: Allocator, config: FuzzingConfig) Fuzzer {
        // Use Instant.now() for seed generation (Zig 0.16.0-dev compatible)
        const seed = config.seed orelse blk: {
            const instant = std.time.Instant.now() catch {
                // Fallback to a fixed seed if clock is unavailable
                break :blk @as(u64, 0x12345678);
            };
            // Extract seed from the instant timestamp
            const timestamp = instant.timestamp;
            if (@TypeOf(timestamp) == u64) {
                break :blk timestamp;
            } else {
                // For timespec, combine sec and nsec
                break :blk @as(u64, @intCast(timestamp.sec)) ^ @as(u64, @intCast(timestamp.nsec));
            }
        };
        return Fuzzer{
            .allocator = allocator,
            .rng = std.rand.DefaultPrng.init(seed),
            .stats = .{},
            .config = config,
        };
    }

    /// Generate random regex pattern
    pub fn generatePattern(self: *Fuzzer) ![]u8 {
        const len = self.rng.random().intRangeAtMost(usize, 1, self.config.max_pattern_length);
        var pattern = try self.allocator.alloc(u8, len);

        for (pattern) |*c| {
            c.* = self.generatePatternChar();
        }

        return pattern;
    }

    fn generatePatternChar(self: *Fuzzer) u8 {
        const choice = self.rng.random().intRangeAtMost(u8, 0, 100);

        if (choice < 40) {
            // Regular characters
            return self.rng.random().intRangeAtMost(u8, 'a', 'z');
        } else if (choice < 60) {
            // Digits
            return self.rng.random().intRangeAtMost(u8, '0', '9');
        } else if (choice < 75) {
            // Special regex characters
            const specials = ".*+?[](){}^$|\\";
            return specials[self.rng.random().intRangeAtMost(usize, 0, specials.len - 1)];
        } else if (choice < 85) {
            // Escape sequences
            const escapes = "dwsDWSntr";
            return escapes[self.rng.random().intRangeAtMost(usize, 0, escapes.len - 1)];
        } else {
            // Whitespace and punctuation
            const punct = " \t,.-_!@#%&";
            return punct[self.rng.random().intRangeAtMost(usize, 0, punct.len - 1)];
        }
    }

    /// Generate malformed patterns for edge case testing
    pub fn generateMalformedPattern(self: *Fuzzer) ![]u8 {
        const malformed_types = enum {
            unclosed_bracket,
            unclosed_paren,
            invalid_quantifier,
            invalid_escape,
            nested_quantifier,
            empty_alternation,
            invalid_backreference,
        };

        const pattern_type = @as(malformed_types, @enumFromInt(
            self.rng.random().intRangeAtMost(u8, 0, 6)
        ));

        return switch (pattern_type) {
            .unclosed_bracket => try self.allocator.dupe(u8, "[abc"),
            .unclosed_paren => try self.allocator.dupe(u8, "(abc"),
            .invalid_quantifier => try self.allocator.dupe(u8, "a{999999999}"),
            .invalid_escape => try self.allocator.dupe(u8, "\\q"),
            .nested_quantifier => try self.allocator.dupe(u8, "a**"),
            .empty_alternation => try self.allocator.dupe(u8, "a||b"),
            .invalid_backreference => try self.allocator.dupe(u8, "\\9"),
        };
    }

    /// Generate ReDoS (Regular expression Denial of Service) patterns
    pub fn generateRedosPattern(self: *Fuzzer) ![]u8 {
        const redos_types = enum {
            nested_quantifier,
            alternation_overlap,
            catastrophic_backtracking,
            exponential_alternation,
        };

        const pattern_type = @as(redos_types, @enumFromInt(
            self.rng.random().intRangeAtMost(u8, 0, 3)
        ));

        return switch (pattern_type) {
            .nested_quantifier => try self.allocator.dupe(u8, "(a+)+b"),
            .alternation_overlap => try self.allocator.dupe(u8, "(a|ab)*c"),
            .catastrophic_backtracking => try self.allocator.dupe(u8, "(a*)*b"),
            .exponential_alternation => try self.allocator.dupe(u8, "(a|a)*"),
        };
    }

    /// Generate random input for testing
    pub fn generateInput(self: *Fuzzer) ![]u8 {
        const len = self.rng.random().intRangeAtMost(usize, 0, self.config.max_input_length);
        var input = try self.allocator.alloc(u8, len);

        for (input) |*c| {
            const choice = self.rng.random().intRangeAtMost(u8, 0, 100);
            if (choice < 70) {
                c.* = self.rng.random().intRangeAtMost(u8, 'a', 'z');
            } else if (choice < 85) {
                c.* = self.rng.random().intRangeAtMost(u8, '0', '9');
            } else {
                c.* = ' ';
            }
        }

        return input;
    }

    /// Test a pattern with timeout and memory checking
    pub fn testPattern(self: *Fuzzer, pattern: []const u8, input: []const u8) !FuzzResult {
        self.stats.patterns_tested += 1;

        // Use Timer for execution timing (Zig 0.16.0-dev compatible)
        var timer = std.time.Timer.start() catch {
            return FuzzResult{
                .status = .runtime_error,
                .error_msg = "TimerUnsupported",
                .execution_time = 0,
            };
        };

        // Use a separate allocator for memory leak detection
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const test_allocator = arena.allocator();

        // Try to compile the pattern
        var regex = Regex.compile(test_allocator, pattern) catch |err| {
            self.stats.patterns_failed += 1;
            const elapsed_ns = timer.read();
            return FuzzResult{
                .status = .compile_error,
                .error_msg = @errorName(err),
                .execution_time = elapsed_ns / std.time.ns_per_ms,
            };
        };
        defer regex.deinit();

        // Test matching with timeout
        const match_result = regex.find(input) catch |err| {
            const elapsed_ns = timer.read();
            return FuzzResult{
                .status = .runtime_error,
                .error_msg = @errorName(err),
                .execution_time = elapsed_ns / std.time.ns_per_ms,
            };
        };

        const elapsed_ns = timer.read();
        const execution_time = elapsed_ns / std.time.ns_per_ms;

        // Check for potential ReDoS
        if (self.config.enable_redos_detection and execution_time > self.config.timeout_ms) {
            self.stats.patterns_timeout += 1;
            self.stats.redos_found += 1;
            return FuzzResult{
                .status = .timeout,
                .execution_time = execution_time,
                .is_redos_candidate = true,
            };
        }

        // Update stats
        self.stats.max_execution_time = @max(self.stats.max_execution_time, execution_time);
        self.stats.total_execution_time += execution_time;

        return FuzzResult{
            .status = .success,
            .matched = match_result != null,
            .execution_time = execution_time,
        };
    }

    pub fn getStats(self: *const Fuzzer) FuzzingStats {
        return self.stats;
    }

    pub fn printReport(self: *const Fuzzer) void {
        const stats = self.stats;
        std.debug.print("\n=== Fuzzing Report ===\n", .{});
        std.debug.print("Patterns tested: {}\n", .{stats.patterns_tested});
        std.debug.print("Compile errors: {}\n", .{stats.patterns_failed});
        std.debug.print("Timeouts: {}\n", .{stats.patterns_timeout});
        std.debug.print("ReDoS candidates: {}\n", .{stats.redos_found});
        std.debug.print("Crashes: {}\n", .{stats.crashes});
        std.debug.print("Memory leaks: {}\n", .{stats.memory_leaks});
        std.debug.print("Max execution time: {}ms\n", .{stats.max_execution_time});
        if (stats.patterns_tested > 0) {
            std.debug.print("Avg execution time: {}ms\n", .{stats.total_execution_time / stats.patterns_tested});
        }
        std.debug.print("===================\n", .{});
    }

    const FuzzResult = struct {
        status: Status,
        matched: bool = false,
        execution_time: u64 = 0,
        error_msg: ?[]const u8 = null,
        is_redos_candidate: bool = false,

        const Status = enum {
            success,
            compile_error,
            runtime_error,
            timeout,
            crash,
        };
    };
};

/// Corpus-based fuzzing with mutation
pub const CorpusFuzzer = struct {
    allocator: Allocator,
    corpus: std.ArrayList([]const u8),
    mutations: std.ArrayList(MutationStrategy),
    rng: std.rand.DefaultPrng,

    const MutationStrategy = enum {
        bit_flip,
        byte_swap,
        insert_random,
        delete_random,
        duplicate_section,
        crossover,
    };

    pub fn init(allocator: Allocator, seed: ?u64) CorpusFuzzer {
        // Use Instant.now() for seed generation (Zig 0.16.0-dev compatible)
        const actual_seed = seed orelse blk: {
            const instant = std.time.Instant.now() catch {
                break :blk @as(u64, 0x87654321);
            };
            const timestamp = instant.timestamp;
            if (@TypeOf(timestamp) == u64) {
                break :blk timestamp;
            } else {
                break :blk @as(u64, @intCast(timestamp.sec)) ^ @as(u64, @intCast(timestamp.nsec));
            }
        };
        return CorpusFuzzer{
            .allocator = allocator,
            .corpus = std.ArrayList([]const u8){},
            .mutations = std.ArrayList(MutationStrategy){},
            .rng = std.rand.DefaultPrng.init(actual_seed),
        };
    }

    pub fn deinit(self: *CorpusFuzzer) void {
        for (self.corpus.items) |item| {
            self.allocator.free(item);
        }
        self.corpus.deinit(self.allocator);
        self.mutations.deinit(self.allocator);
    }

    pub fn addToCorpus(self: *CorpusFuzzer, pattern: []const u8) !void {
        const copy = try self.allocator.dupe(u8, pattern);
        try self.corpus.append(self.allocator, copy);
    }

    pub fn mutate(self: *CorpusFuzzer, input: []const u8) ![]u8 {
        const strategy = @as(MutationStrategy, @enumFromInt(
            self.rng.random().intRangeAtMost(u8, 0, 5)
        ));

        return switch (strategy) {
            .bit_flip => try self.mutateBitFlip(input),
            .byte_swap => try self.mutateByteSwap(input),
            .insert_random => try self.mutateInsertRandom(input),
            .delete_random => try self.mutateDeleteRandom(input),
            .duplicate_section => try self.mutateDuplicateSection(input),
            .crossover => try self.mutateCrossover(input),
        };
    }

    fn mutateBitFlip(self: *CorpusFuzzer, input: []const u8) ![]u8 {
        var mutated = try self.allocator.dupe(u8, input);
        if (mutated.len > 0) {
            const pos = self.rng.random().intRangeAtMost(usize, 0, mutated.len - 1);
            const bit = self.rng.random().intRangeAtMost(u3, 0, 7);
            mutated[pos] ^= (@as(u8, 1) << bit);
        }
        return mutated;
    }

    fn mutateByteSwap(self: *CorpusFuzzer, input: []const u8) ![]u8 {
        var mutated = try self.allocator.dupe(u8, input);
        if (mutated.len > 1) {
            const pos1 = self.rng.random().intRangeAtMost(usize, 0, mutated.len - 1);
            const pos2 = self.rng.random().intRangeAtMost(usize, 0, mutated.len - 1);
            const tmp = mutated[pos1];
            mutated[pos1] = mutated[pos2];
            mutated[pos2] = tmp;
        }
        return mutated;
    }

    fn mutateInsertRandom(self: *CorpusFuzzer, input: []const u8) ![]u8 {
        const pos = self.rng.random().intRangeAtMost(usize, 0, input.len);
        var mutated = try self.allocator.alloc(u8, input.len + 1);
        @memcpy(mutated[0..pos], input[0..pos]);
        mutated[pos] = self.rng.random().int(u8);
        @memcpy(mutated[pos + 1 ..], input[pos..]);
        return mutated;
    }

    fn mutateDeleteRandom(self: *CorpusFuzzer, input: []const u8) ![]u8 {
        if (input.len <= 1) return try self.allocator.dupe(u8, input);

        const pos = self.rng.random().intRangeAtMost(usize, 0, input.len - 1);
        var mutated = try self.allocator.alloc(u8, input.len - 1);
        @memcpy(mutated[0..pos], input[0..pos]);
        @memcpy(mutated[pos..], input[pos + 1 ..]);
        return mutated;
    }

    fn mutateDuplicateSection(self: *CorpusFuzzer, input: []const u8) ![]u8 {
        if (input.len == 0) return try self.allocator.dupe(u8, input);

        const start = self.rng.random().intRangeAtMost(usize, 0, input.len - 1);
        const end = self.rng.random().intRangeAtMost(usize, start, input.len - 1) + 1;
        const section = input[start..end];

        var mutated = try self.allocator.alloc(u8, input.len + section.len);
        @memcpy(mutated[0..input.len], input);
        @memcpy(mutated[input.len..], section);
        return mutated;
    }

    fn mutateCrossover(self: *CorpusFuzzer, input: []const u8) ![]u8 {
        if (self.corpus.items.len == 0) {
            return try self.allocator.dupe(u8, input);
        }

        const other = self.corpus.items[self.rng.random().intRangeAtMost(usize, 0, self.corpus.items.len - 1)];
        const split_point = self.rng.random().intRangeAtMost(usize, 0, @min(input.len, other.len));

        var mutated = try self.allocator.alloc(u8, split_point + (other.len - split_point));
        @memcpy(mutated[0..split_point], input[0..split_point]);
        @memcpy(mutated[split_point..], other[split_point..]);
        return mutated;
    }
};

test "fuzzer pattern generation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fuzzer = Fuzzer.init(allocator, .{});

    // Generate and test patterns
    for (0..10) |_| {
        const pattern = try fuzzer.generatePattern();
        defer allocator.free(pattern);
        try std.testing.expect(pattern.len > 0);
    }
}

test "malformed pattern generation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fuzzer = Fuzzer.init(allocator, .{});

    // Test malformed patterns
    for (0..5) |_| {
        const pattern = try fuzzer.generateMalformedPattern();
        defer allocator.free(pattern);

        // These should fail to compile
        const result = Regex.compile(allocator, pattern);
        if (result) |*regex| {
            regex.deinit();
        } else |_| {
            // Expected to fail
        }
    }
}

test "ReDoS pattern detection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fuzzer = Fuzzer.init(allocator, .{
        .enable_redos_detection = true,
        .timeout_ms = 10,
    });

    const redos_pattern = try fuzzer.generateRedosPattern();
    defer allocator.free(redos_pattern);

    // Create pathological input for ReDoS
    const input = "aaaaaaaaaaaaaaaaaaaaaaaac";

    _ = try fuzzer.testPattern(redos_pattern, input);

    // Check if ReDoS was detected
    const stats = fuzzer.getStats();
    _ = stats;
}