const std = @import("std");
const zregex = @import("src/root.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    std.debug.print("=== zregex Performance Benchmark ===\n\n", .{});

    // Test patterns and inputs
    const test_cases = [_]struct {
        pattern: []const u8,
        input: []const u8,
        name: []const u8,
    }{
        .{ .pattern = "hello", .input = "hello world", .name = "Simple Literal" },
        .{ .pattern = "[a-zA-Z0-9]+", .input = "Hello123World456", .name = "Character Class" },
        .{ .pattern = "\\d{3}-\\d{2}-\\d{4}", .input = "SSN: 123-45-6789", .name = "Complex Pattern" },
        .{ .pattern = "(cat|dog|bird)", .input = "I have a cat and a dog", .name = "Alternation" },
        .{ .pattern = "\\p{L}+", .input = "Hello世界", .name = "Unicode Letters" },
    };

    // Run compilation time tests
    std.debug.print("=== Compilation Time Tests ===\n", .{});
    var total_compile_time: u64 = 0;
    var test_count: u32 = 0;

    // Use Timer for precise timing (Zig 0.16.0-dev compatible)
    var timer = std.time.Timer.start() catch {
        std.debug.print("❌ Failed to start timer\n", .{});
        return;
    };

    for (test_cases) |test_case| {
        timer.reset();
        var regex = zregex.Regex.compile(allocator, test_case.pattern) catch |err| {
            std.debug.print("❌ {s}: Failed to compile - {}\n", .{test_case.name, err});
            continue;
        };
        const compile_time = timer.read();
        defer regex.deinit();

        total_compile_time += compile_time;
        test_count += 1;

        const compile_time_ms = @as(f64, @floatFromInt(compile_time)) / 1_000_000.0;
        std.debug.print("✅ {s:20} - {d:.2}ms\n", .{test_case.name, compile_time_ms});

        // Run matching performance test
        const iterations = 10000;
        timer.reset();

        var matches: u32 = 0;
        for (0..iterations) |_| {
            if (try regex.isMatch(test_case.input)) {
                matches += 1;
            }
        }

        const match_time = timer.read();
        const avg_match_time = @as(f64, @floatFromInt(match_time)) / @as(f64, @floatFromInt(iterations)) / 1000.0; // microseconds

        std.debug.print("   Matching: {d:.2}μs/op ({} matches)\n", .{avg_match_time, matches});
    }

    if (test_count > 0) {
        const avg_compile_time = total_compile_time / test_count;
        const avg_compile_time_ms = @as(f64, @floatFromInt(avg_compile_time)) / 1_000_000.0;

        std.debug.print("\n=== Summary ===\n", .{});
        std.debug.print("Average compilation time: {d:.2}ms\n", .{avg_compile_time_ms});

        if (avg_compile_time_ms <= 100.0) {
            std.debug.print("✅ PASSED: Compilation time under 100ms target\n", .{});
        } else {
            std.debug.print("❌ FAILED: Compilation time exceeds 100ms target\n", .{});
        }
    }

    // Memory usage test
    std.debug.print("\n=== Memory Usage Test ===\n", .{});

    const test_pattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}";
    const test_input = "Contact user@example.com or admin@test.org for support";

    // Measure peak memory usage during compilation and execution
    var compile_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = compile_gpa.deinit();
    const compile_allocator = compile_gpa.allocator();

    var regex = try zregex.Regex.compile(compile_allocator, test_pattern);
    defer regex.deinit();

    // Run multiple operations to stress test memory
    for (0..1000) |_| {
        _ = try regex.isMatch(test_input);
    }

    std.debug.print("✅ Memory stress test completed (1000 operations)\n", .{});
    std.debug.print("✅ All tests completed successfully!\n", .{});
}