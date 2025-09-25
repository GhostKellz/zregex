const std = @import("std");
const zregex = @import("src/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test the failing case
    std.debug.print("Testing a* pattern...\n", .{});

    var regex = try zregex.Regex.compile(allocator, "a*");
    defer regex.deinit();

    const empty_result = try regex.isMatch("");
    std.debug.print("Empty string match: {}\n", .{empty_result});

    const bbb_result = try regex.isMatch("bbb");
    std.debug.print("'bbb' match: {}\n", .{bbb_result});

    const a_result = try regex.isMatch("a");
    std.debug.print("'a' match: {}\n", .{a_result});

    // Debug NFA structure
    if (regex.compiled.nfa) |nfa| {
        std.debug.print("NFA has {} states\n", .{nfa.states.items.len});
        std.debug.print("Start state: {}\n", .{nfa.start_state});
        std.debug.print("Accept states: ", .{});
        for (nfa.accept_states.items) |state_id| {
            std.debug.print("{} ", .{state_id});
        }
        std.debug.print("\n", .{});

        for (nfa.states.items, 0..) |state, i| {
            std.debug.print("State {}: is_accept={}, transitions={}\n", .{ i, state.is_accept, state.transitions.items.len });
            for (state.transitions.items) |trans| {
                switch (trans.condition) {
                    .epsilon => std.debug.print("  -> {} (epsilon)\n", .{trans.target}),
                    .char => |c| std.debug.print("  -> {} (char '{c}')\n", .{ trans.target, c }),
                    .any_char => std.debug.print("  -> {} (any_char)\n", .{trans.target}),
                    .char_class => std.debug.print("  -> {} (char_class)\n", .{trans.target}),
                }
            }
        }
    }
}