const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a simple test without build_options
    const parser = @import("src/parser.zig");
    const nfa_builder = @import("src/nfa_builder.zig");
    const matcher = @import("src/matcher.zig");

    std.debug.print("Testing a* pattern construction...\n", .{});

    var parser_inst = parser.Parser.init(allocator, "a*");
    var ast = try parser_inst.parse();
    defer ast.deinit();

    var builder = try nfa_builder.NFABuilder.init(allocator);
    defer builder.deinit();

    const nfa = try builder.build(&ast);
    defer nfa.deinit(allocator);

    std.debug.print("NFA built with {} states\n", .{nfa.states.items.len});
    std.debug.print("Start state: {}\n", .{nfa.start_state});

    for (nfa.states.items, 0..) |state, i| {
        std.debug.print("State {}: accept={}\n", .{ i, state.is_accept });
        for (state.transitions.items) |trans| {
            switch (trans.condition) {
                .epsilon => std.debug.print("  -> {} (epsilon)\n", .{trans.target}),
                .char => |c| std.debug.print("  -> {} (char '{c}')\n", .{ trans.target, c }),
                else => std.debug.print("  -> {} (other)\n", .{trans.target}),
            }
        }
    }

    // Test matching
    const nfa_matcher = matcher.NFAMatcher.init(allocator, nfa);

    const empty_match = try nfa_matcher.findMatch("");
    std.debug.print("Empty string match: {?}\n", .{empty_match});

    const a_match = try nfa_matcher.findMatch("a");
    std.debug.print("'a' match: {?}\n", .{a_match});

    const bbb_match = try nfa_matcher.findMatch("bbb");
    std.debug.print("'bbb' match: {?}\n", .{bbb_match});
}