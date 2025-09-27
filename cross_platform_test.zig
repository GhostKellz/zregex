const std = @import("std");

// Cross-platform build validation script
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const targets = [_][]const u8{
        "x86_64-linux-gnu",
        "aarch64-linux-gnu",
        "x86_64-macos-none",
        "aarch64-macos-none",
        "x86_64-windows-gnu",
        "wasm32-wasi",
    };

    std.debug.print("=== zregex Cross-Platform Build Validation ===\n\n", .{});

    var success_count: u32 = 0;
    var total_count: u32 = 0;

    for (targets) |target| {
        total_count += 1;
        std.debug.print("Testing target: {s}\n", .{target});

        // Try to build for this target
        const target_arg = try std.fmt.allocPrint(allocator, "-Dtarget={s}", .{target});
        defer allocator.free(target_arg);

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "zig", "build", target_arg, "-Doptimize=ReleaseSafe"
            },
        }) catch |err| {
            std.debug.print("  ❌ FAILED to execute build: {}\n\n", .{err});
            continue;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited == 0) {
            std.debug.print("  ✅ BUILD SUCCESS\n", .{});
            success_count += 1;

            // For native targets, also try to run tests
            if (std.mem.eql(u8, target, "x86_64-linux-gnu")) {
                std.debug.print("  Running tests for native target...\n", .{});
                const test_result = std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &[_][]const u8{
                        "zig", "build", "test", target_arg
                    },
                }) catch |err| {
                    std.debug.print("  ⚠️  Tests failed to execute: {}\n", .{err});
                    continue;
                };
                defer allocator.free(test_result.stdout);
                defer allocator.free(test_result.stderr);

                if (test_result.term.Exited == 0) {
                    std.debug.print("  ✅ TESTS PASSED\n", .{});
                } else {
                    std.debug.print("  ❌ TESTS FAILED\n", .{});
                    std.debug.print("  Error output: {s}\n", .{test_result.stderr});
                }
            }
        } else {
            std.debug.print("  ❌ BUILD FAILED\n", .{});
            if (result.stderr.len > 0) {
                std.debug.print("  Error: {s}\n", .{result.stderr});
            }
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("=== Summary ===\n", .{});
    std.debug.print("Successful builds: {}/{}\n", .{success_count, total_count});
    std.debug.print("Success rate: {d:.1}%\n", .{@as(f64, @floatFromInt(success_count)) * 100.0 / @as(f64, @floatFromInt(total_count))});

    if (success_count == total_count) {
        std.debug.print("🎉 ALL TARGETS PASSED!\n", .{});
    } else {
        std.debug.print("⚠️  Some targets failed - see details above\n", .{});
    }
}