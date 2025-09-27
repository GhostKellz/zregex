const std = @import("std");
const zregex = @import("src/root.zig");
const benchmarks = @import("src/benchmarks.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== zregex Performance Benchmark Suite ===\n\n", .{});

    // Initialize benchmark suite with moderate iterations for quick results
    var suite = benchmarks.BenchmarkSuite.init(allocator, .{
        .warmup_iterations = 100,
        .test_iterations = 1000,
        .timeout_ms = 10000,
        .memory_tracking = true,
        .detailed_stats = true,
    });
    defer suite.deinit();

    // Run standard benchmarks
    try suite.runStandardBenchmarks();

    // Print results
    suite.printSummary();

    // Export to CSV for analysis
    try suite.exportCSV("benchmark_results.csv");
    std.debug.print("\n📊 Results exported to benchmark_results.csv\n", .{});

    // Run compilation time tests
    std.debug.print("\n=== Compilation Time Tests ===\n", .{});
    const compile_patterns = [_][]const u8{
        "hello",
        "[a-zA-Z0-9]+",
        "(cat|dog|bird)",
        "\\d{3}-\\d{2}-\\d{4}",
        "\\p{Letter}+",
        "^.*(?:test|benchmark).*$",
        "(\\w+)@(\\w+\\.)+(\\w+)",
        "\\b(?:[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*|\"(?:[\\x01-\\x08\\x0b\\x0c\\x0e-\\x1f\\x21\\x23-\\x5b\\x5d-\\x7f]|\\\\[\\x01-\\x09\\x0b\\x0c\\x0e-\\x7f])*\")@(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|\\[(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?|[a-z0-9-]*[a-z0-9]:(?:[\\x01-\\x08\\x0b\\x0c\\x0e-\\x1f\\x21-\\x5a\\x53-\\x7f]|\\\\[\\x01-\\x09\\x0b\\x0c\\x0e-\\x7f])+)\\])\\b",
    };

    var total_compile_time: u64 = 0;
    var compiled_count: u32 = 0;

    for (compile_patterns) |pattern| {
        const start = std.time.nanoTimestamp();
        var regex = zregex.Regex.compile(allocator, pattern) catch |err| {
            std.debug.print("❌ Failed to compile: {s} - {}\n", .{pattern, err});
            continue;
        };
        const end = std.time.nanoTimestamp();
        regex.deinit();

        const compile_time = @as(u64, @intCast(end - start));
        total_compile_time += compile_time;
        compiled_count += 1;

        const compile_time_ms = @as(f64, @floatFromInt(compile_time)) / 1_000_000.0;
        std.debug.print("✅ {s:30} - {d:.2}ms\n", .{pattern[0..@min(pattern.len, 30)], compile_time_ms});

        if (compile_time_ms > 100.0) {
            std.debug.print("⚠️  SLOW: Compilation time exceeds 100ms target!\n", .{});
        }
    }

    if (compiled_count > 0) {
        const avg_compile_time = total_compile_time / compiled_count;
        const avg_compile_time_ms = @as(f64, @floatFromInt(avg_compile_time)) / 1_000_000.0;
        std.debug.print("\n📈 Average compilation time: {d:.2}ms\n", .{avg_compile_time_ms});

        if (avg_compile_time_ms <= 100.0) {
            std.debug.print("✅ PASSED: Average compilation time under 100ms target\n", .{});
        } else {
            std.debug.print("❌ FAILED: Average compilation time exceeds 100ms target\n", .{});
        }
    }

    std.debug.print("\n🎯 Benchmark suite completed successfully!\n", .{});
}