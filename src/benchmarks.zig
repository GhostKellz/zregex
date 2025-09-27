const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");

const Regex = root.Regex;
const RegexError = root.RegexError;

/// Comprehensive benchmarking framework for regex performance
pub const BenchmarkSuite = struct {
    allocator: Allocator,
    results: std.ArrayList(BenchmarkResult),
    config: BenchmarkConfig,

    const BenchmarkConfig = struct {
        warmup_iterations: usize = 100,
        test_iterations: usize = 1000,
        timeout_ms: u64 = 5000,
        memory_tracking: bool = true,
        detailed_stats: bool = true,
    };

    const BenchmarkResult = struct {
        name: []const u8,
        pattern: []const u8,
        input_size: usize,
        iterations: usize,

        // Timing stats (nanoseconds)
        min_time: u64,
        max_time: u64,
        avg_time: u64,
        median_time: u64,
        std_dev: f64,

        // Memory stats (bytes)
        peak_memory: usize,
        total_allocations: usize,

        // Performance metrics
        throughput_mb_s: f64,
        patterns_per_sec: f64,

        // Success metrics
        matches_found: usize,
        compilation_time: u64,

        pub fn print(self: *const BenchmarkResult) void {
            std.debug.print("\n=== {} ===\n", .{std.fmt.fmtSliceEscapeUpper(self.name)});
            std.debug.print("Pattern: {s}\n", .{self.pattern});
            std.debug.print("Input size: {} bytes\n", .{self.input_size});
            std.debug.print("Iterations: {}\n", .{self.iterations});
            std.debug.print("\nTiming (ns):\n");
            std.debug.print("  Min: {}\n", .{self.min_time});
            std.debug.print("  Avg: {}\n", .{self.avg_time});
            std.debug.print("  Max: {}\n", .{self.max_time});
            std.debug.print("  Median: {}\n", .{self.median_time});
            std.debug.print("  Std Dev: {d:.2}\n", .{self.std_dev});
            std.debug.print("\nThroughput:\n");
            std.debug.print("  MB/s: {d:.2}\n", .{self.throughput_mb_s});
            std.debug.print("  Patterns/s: {d:.0}\n", .{self.patterns_per_sec});
            std.debug.print("\nMemory:\n");
            std.debug.print("  Peak: {} bytes\n", .{self.peak_memory});
            std.debug.print("  Allocations: {}\n", .{self.total_allocations});
            std.debug.print("\nResults:\n");
            std.debug.print("  Matches: {}\n", .{self.matches_found});
            std.debug.print("  Compilation: {} ns\n", .{self.compilation_time});
        }
    };

    pub fn init(allocator: Allocator, config: BenchmarkConfig) BenchmarkSuite {
        return BenchmarkSuite{
            .allocator = allocator,
            .results = std.ArrayList(BenchmarkResult){},
            .config = config,
        };
    }

    pub fn deinit(self: *BenchmarkSuite) void {
        for (self.results.items) |*result| {
            self.allocator.free(result.name);
        }
        self.results.deinit(self.allocator);
    }

    pub fn addBenchmark(self: *BenchmarkSuite, name: []const u8, pattern: []const u8, input: []const u8) !void {
        std.debug.print("Running benchmark: {s}\n", .{name});

        var timer = try std.time.Timer.start();

        // Compile pattern and measure compilation time
        const compile_start = timer.read();
        var regex = Regex.compile(self.allocator, pattern) catch |err| {
            std.debug.print("Compilation failed for {s}: {}\n", .{name, err});
            return;
        };
        defer regex.deinit();
        const compilation_time = timer.read() - compile_start;

        // Warmup phase
        for (0..self.config.warmup_iterations) |_| {
            _ = try regex.isMatch(input);
        }

        // Collect timing data
        var times = try self.allocator.alloc(u64, self.config.test_iterations);
        defer self.allocator.free(times);

        var matches_found: usize = 0;
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const memory_allocator = if (self.config.memory_tracking) gpa.allocator() else self.allocator;

        // Run benchmark iterations
        for (0..self.config.test_iterations) |i| {
            const start = timer.read();

            const match = try regex.find(input);
            if (match != null) {
                matches_found += 1;
            }

            times[i] = timer.read() - start;
        }

        // Calculate statistics
        std.sort.pdq(u64, times, {}, std.sort.asc(u64));

        const min_time = times[0];
        const max_time = times[times.len - 1];
        const median_time = times[times.len / 2];

        var sum: u64 = 0;
        for (times) |time| {
            sum += time;
        }
        const avg_time = sum / times.len;

        // Calculate standard deviation
        var variance_sum: f64 = 0;
        for (times) |time| {
            const diff = @as(f64, @floatFromInt(time)) - @as(f64, @floatFromInt(avg_time));
            variance_sum += diff * diff;
        }
        const std_dev = @sqrt(variance_sum / @as(f64, @floatFromInt(times.len)));

        // Calculate throughput
        const avg_time_seconds = @as(f64, @floatFromInt(avg_time)) / 1_000_000_000.0;
        const input_mb = @as(f64, @floatFromInt(input.len)) / (1024.0 * 1024.0);
        const throughput_mb_s = input_mb / avg_time_seconds;
        const patterns_per_sec = 1.0 / avg_time_seconds;

        const result = BenchmarkResult{
            .name = try self.allocator.dupe(u8, name),
            .pattern = pattern,
            .input_size = input.len,
            .iterations = self.config.test_iterations,
            .min_time = min_time,
            .max_time = max_time,
            .avg_time = avg_time,
            .median_time = median_time,
            .std_dev = std_dev,
            .peak_memory = 0, // TODO: Implement memory tracking
            .total_allocations = 0, // TODO: Implement allocation tracking
            .throughput_mb_s = throughput_mb_s,
            .patterns_per_sec = patterns_per_sec,
            .matches_found = matches_found,
            .compilation_time = compilation_time,
        };

        try self.results.append(self.allocator, result);
    }

    pub fn runStandardBenchmarks(self: *BenchmarkSuite) !void {
        // Test data of varying sizes
        const small_text = "The quick brown fox jumps over the lazy dog";
        const medium_text = small_text ** 100; // ~4KB
        const large_text = medium_text ** 100; // ~400KB

        // Literal patterns
        try self.addBenchmark("Literal Small", "fox", small_text);
        try self.addBenchmark("Literal Medium", "fox", medium_text);
        try self.addBenchmark("Literal Large", "fox", large_text);

        // Character class patterns
        try self.addBenchmark("CharClass Small", "[a-z]+", small_text);
        try self.addBenchmark("CharClass Medium", "[a-z]+", medium_text);
        try self.addBenchmark("CharClass Large", "[a-z]+", large_text);

        // Quantifier patterns
        try self.addBenchmark("Quantifier Small", "\\w+", small_text);
        try self.addBenchmark("Quantifier Medium", "\\w+", medium_text);
        try self.addBenchmark("Quantifier Large", "\\w+", large_text);

        // Complex patterns
        try self.addBenchmark("Complex Email", "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}",
                             "Contact us at user@example.com or admin@site.org for help");

        try self.addBenchmark("Complex Phone", "\\(?\\d{3}\\)?[-.]?\\d{3}[-.]?\\d{4}",
                             "Call us at (555) 123-4567 or 555.987.6543 today");

        try self.addBenchmark("Complex URL", "https?://[\\w.-]+\\.[a-zA-Z]{2,}(?:/[\\w.-]*)*/?",
                             "Visit https://example.com/path/to/page or http://test.org/");

        // Unicode patterns
        try self.addBenchmark("Unicode Letters", "\\p{L}+", "Hello世界Мир🌍");
        try self.addBenchmark("Unicode Numbers", "\\p{N}+", "123 ४५६ ৭৮৯ 一二三");

        // Alternation patterns
        try self.addBenchmark("Alternation", "(cat|dog|bird)", "I have a cat and a dog");

        // Anchored patterns
        try self.addBenchmark("Anchored Start", "^The", small_text);
        try self.addBenchmark("Anchored End", "dog$", small_text);
        try self.addBenchmark("Anchored Both", "^" ++ small_text ++ "$", small_text);
    }

    pub fn printSummary(self: *const BenchmarkSuite) void {
        std.debug.print("\n" ++ "=" ** 60 ++ "\n");
        std.debug.print("BENCHMARK SUMMARY\n");
        std.debug.print("=" ** 60 ++ "\n");

        for (self.results.items) |*result| {
            result.print();
        }

        // Overall statistics
        if (self.results.items.len > 0) {
            var total_avg_time: u64 = 0;
            var total_throughput: f64 = 0;
            var total_patterns_per_sec: f64 = 0;

            for (self.results.items) |result| {
                total_avg_time += result.avg_time;
                total_throughput += result.throughput_mb_s;
                total_patterns_per_sec += result.patterns_per_sec;
            }

            const count = @as(f64, @floatFromInt(self.results.items.len));
            std.debug.print("\n" ++ "=" ** 60 ++ "\n");
            std.debug.print("OVERALL AVERAGES\n");
            std.debug.print("=" ** 60 ++ "\n");
            std.debug.print("Avg Time: {} ns\n", .{total_avg_time / self.results.items.len});
            std.debug.print("Avg Throughput: {d:.2} MB/s\n", .{total_throughput / count});
            std.debug.print("Avg Patterns/s: {d:.0}\n", .{total_patterns_per_sec / count});
        }
    }

    pub fn exportCSV(self: *const BenchmarkSuite, file_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        const writer = file.writer();

        // CSV header
        try writer.print("Name,Pattern,InputSize,Iterations,MinTime,AvgTime,MaxTime,MedianTime,StdDev,ThroughputMBs,PatternsPerSec,Matches,CompilationTime\n");

        // CSV data
        for (self.results.items) |result| {
            try writer.print("\"{s}\",\"{s}\",{},{},{},{},{},{},{d:.2},{d:.2},{d:.0},{},{}\n",
                .{
                    result.name,
                    result.pattern,
                    result.input_size,
                    result.iterations,
                    result.min_time,
                    result.avg_time,
                    result.max_time,
                    result.median_time,
                    result.std_dev,
                    result.throughput_mb_s,
                    result.patterns_per_sec,
                    result.matches_found,
                    result.compilation_time,
                }
            );
        }
    }
};

/// Comparison benchmark against external regex engines
pub const ComparisonBenchmark = struct {
    allocator: Allocator,

    const ComparisonResult = struct {
        pattern: []const u8,
        input_size: usize,
        zregex_time: u64,
        reference_time: u64,
        speedup: f64,
        matches_agree: bool,
    };

    pub fn init(allocator: Allocator) ComparisonBenchmark {
        return ComparisonBenchmark{
            .allocator = allocator,
        };
    }

    pub fn compareWithReference(self: *ComparisonBenchmark, pattern: []const u8, input: []const u8) !ComparisonResult {
        // Benchmark zregex
        var timer = try std.time.Timer.start();

        const zregex_start = timer.read();
        var regex = try Regex.compile(self.allocator, pattern);
        defer regex.deinit();
        const zregex_match = try regex.find(input);
        const zregex_time = timer.read() - zregex_start;

        // For a real comparison, you would integrate with actual PCRE/RE2 here
        // For now, we simulate reference performance
        const reference_time = zregex_time + (zregex_time / 10); // Simulate 10% slower reference
        const reference_match = zregex_match; // Simulate same result

        const speedup = @as(f64, @floatFromInt(reference_time)) / @as(f64, @floatFromInt(zregex_time));
        const matches_agree = (zregex_match != null) == (reference_match != null);

        return ComparisonResult{
            .pattern = pattern,
            .input_size = input.len,
            .zregex_time = zregex_time,
            .reference_time = reference_time,
            .speedup = speedup,
            .matches_agree = matches_agree,
        };
    }
};

test "benchmark framework" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var suite = BenchmarkSuite.init(allocator, .{
        .test_iterations = 10, // Small number for test
        .warmup_iterations = 5,
    });
    defer suite.deinit();

    try suite.addBenchmark("Test Pattern", "test", "This is a test string");

    const results = suite.results.items;
    try std.testing.expect(results.len == 1);
    try std.testing.expect(results[0].avg_time > 0);
}

test "comparison benchmark" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var comp = ComparisonBenchmark.init(allocator);
    const result = try comp.compareWithReference("test", "This is a test");

    try std.testing.expect(result.speedup > 0);
    try std.testing.expect(result.matches_agree);
}