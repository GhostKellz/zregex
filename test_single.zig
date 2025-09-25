const std = @import("std");
const root = @import("src/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Testing simple a* compilation and matching...\\n", .{});

    var regex = root.Regex.compile(allocator, "a*") catch |err| {
        std.debug.print("Compile error: {}\\n", .{err});
        return;
    };
    defer regex.deinit();

    std.debug.print("Compiled successfully, testing isMatch...\\n", .{});

    const result = regex.isMatch("") catch |err| {
        std.debug.print("Match error: {}\\n", .{err});
        return;
    };

    std.debug.print("isMatch(\"\") result: {}\\n", .{result});

    // Also test with non-empty
    const result_a = regex.isMatch("a") catch |err| {
        std.debug.print("Match error for 'a': {}\\n", .{err});
        return;
    };
    std.debug.print("isMatch(\"a\") result: {}\\n", .{result_a});
}