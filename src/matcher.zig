const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");
const unicode = @import("unicode.zig");

const NFA = root.NFA;
const Match = root.Match;
const RegexError = root.RegexError;

pub const NFAMatcher = struct {
    nfa: *const NFA,
    allocator: Allocator,
    capture_groups: bool = true,

    pub fn init(allocator: Allocator, nfa: *const NFA) NFAMatcher {
        return NFAMatcher{
            .nfa = nfa,
            .allocator = allocator,
        };
    }

    pub fn findMatch(self: *const NFAMatcher, input: []const u8) RegexError!?Match {
        return self.findMatchWithGroups(input, null);
    }

    pub fn findMatchWithGroups(self: *const NFAMatcher, input: []const u8, groups: ?*std.ArrayList(?Match)) RegexError!?Match {
        for (0..input.len + 1) |start_pos| {
            if (try self.matchAtWithGroups(input, start_pos, groups)) |end_pos| {
                return Match{
                    .start = start_pos,
                    .end = end_pos,
                    .groups = if (groups) |g| g.items else null,
                };
            }
        }
        return null;
    }

    fn matchAt(self: *const NFAMatcher, input: []const u8, start_pos: usize) RegexError!?usize {
        return self.matchAtWithGroups(input, start_pos, null);
    }

    fn matchAtWithGroups(self: *const NFAMatcher, input: []const u8, start_pos: usize, groups: ?*std.ArrayList(?Match)) RegexError!?usize {
        var current_states = std.ArrayList(u32){};
        defer current_states.deinit(self.allocator);

        var next_states = std.ArrayList(u32){};
        defer next_states.deinit(self.allocator);

        try self.addEpsilonClosure(&current_states, self.nfa.start_state);


        var pos = start_pos;
        while (pos <= input.len) {
            if (self.hasAcceptState(&current_states)) {
                return pos;
            }

            if (pos >= input.len) break;

            const char = input[pos];
            if (groups) |_| {
            // TODO: Implement group capture tracking
        }
        try self.stepStates(&current_states, &next_states, char);

            const tmp = current_states;
            current_states = next_states;
            next_states = tmp;
            next_states.clearRetainingCapacity();

            pos += 1;
        }

        if (self.hasAcceptState(&current_states)) {
            return pos;
        }

        return null;
    }

    fn addEpsilonClosure(self: *const NFAMatcher, states: *std.ArrayList(u32), state_id: u32) RegexError!void {
        var visited = std.ArrayList(bool){};
        defer visited.deinit(self.allocator);

        try visited.resize(self.allocator, self.nfa.states.items.len);
        for (visited.items) |*v| v.* = false;

        try self.addEpsilonClosureRec(states, state_id, &visited);
    }

    fn addEpsilonClosureRec(self: *const NFAMatcher, states: *std.ArrayList(u32), state_id: u32, visited: *std.ArrayList(bool)) RegexError!void {
        if (state_id >= self.nfa.states.items.len or visited.items[state_id]) {
            return;
        }

        visited.items[state_id] = true;
        try states.append(self.allocator, state_id);

        const state = &self.nfa.states.items[state_id];
        for (state.transitions.items) |transition| {
            if (transition.condition == .epsilon) {
                try self.addEpsilonClosureRec(states, transition.target, visited);
            }
        }
    }

    fn stepStates(self: *const NFAMatcher, current: *std.ArrayList(u32), next: *std.ArrayList(u32), char: u8) RegexError!void {
        for (current.items) |state_id| {
            const state = &self.nfa.states.items[state_id];
            for (state.transitions.items) |transition| {
                if (self.matchesTransition(transition.condition, char)) {
                    try self.addEpsilonClosure(next, transition.target);
                }
            }
        }
    }

    fn matchesTransition(self: *const NFAMatcher, condition: NFA.TransitionCondition, char: u8) bool {
        _ = self;
        switch (condition) {
            .epsilon => return false,
            .char => |c| return c == char,
            .any_char => return char != '\n', // . doesn't match newline by default
            .char_class => |*char_class| {
                const codepoint: u21 = char; // For now, treat as ASCII
                for (char_class.ranges.items) |range| {
                    if (codepoint >= range.start and codepoint <= range.end) {
                        return !char_class.negated;
                    }
                }
                return char_class.negated;
            },
        }
    }

    fn matchesTransitionUnicode(self: *const NFAMatcher, condition: NFA.TransitionCondition, codepoint: u21) bool {
        _ = self;
        switch (condition) {
            .epsilon => return false,
            .char => |c| return c == codepoint and codepoint <= 127, // ASCII only for char
            .any_char => return codepoint != '\n',
            .char_class => |*char_class| {
                for (char_class.ranges.items) |range| {
                    if (codepoint >= range.start and codepoint <= range.end) {
                        return !char_class.negated;
                    }
                }
                return char_class.negated;
            },
        }
    }

    fn hasAcceptState(self: *const NFAMatcher, states: *const std.ArrayList(u32)) bool {
        for (states.items) |state_id| {
            if (self.nfa.states.items[state_id].is_accept) {
                return true;
            }
        }
        return false;
    }
};

test "nfa matcher basic literal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try root.Regex.compile(allocator, "hello");
    defer regex.deinit();

    const matcher = NFAMatcher.init(allocator, regex.compiled.nfa.?);
    const result = try matcher.findMatch("hello world");

    try std.testing.expect(result != null);
    try std.testing.expect(result.?.start == 0);
    try std.testing.expect(result.?.end == 5);
}

test "nfa matcher no match" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try root.Regex.compile(allocator, "xyz");
    defer regex.deinit();

    const matcher = NFAMatcher.init(allocator, regex.compiled.nfa.?);
    const result = try matcher.findMatch("hello world");

    try std.testing.expect(result == null);
}