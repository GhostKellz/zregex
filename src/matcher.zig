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

    const GroupCapture = struct {
        group_id: u32,
        start: ?usize = null,
        end: ?usize = null,
    };

    pub fn findMatch(self: *const NFAMatcher, input: []const u8) RegexError!?Match {
        return self.findMatchFrom(input, 0);
    }

    pub fn findMatchFrom(self: *const NFAMatcher, input: []const u8, start_offset: usize) RegexError!?Match {
        return self.findMatchFromWithGroups(input, start_offset, null);
    }

    pub fn findMatchWithGroups(self: *const NFAMatcher, input: []const u8, groups: ?*std.ArrayList(?Match)) RegexError!?Match {
        return self.findMatchFromWithGroups(input, 0, groups);
    }

    pub fn isMatchOnly(self: *const NFAMatcher, input: []const u8) RegexError!bool {
        // Efficient boolean-only matching without group allocation
        var pos: usize = 0;
        while (pos <= input.len) : (pos += 1) {
            if (try self.matchAt(input, pos)) |_| {
                return true;
            }
        }
        return false;
    }

    fn findMatchFromWithGroups(self: *const NFAMatcher, input: []const u8, start_offset: usize, groups: ?*std.ArrayList(?Match)) RegexError!?Match {
        var pos = start_offset;
        while (pos <= input.len) : (pos += 1) {
            if (groups) |g| g.clearRetainingCapacity();
            if (try self.matchAtWithGroups(input, pos, groups)) |end_pos| {
                var groups_slice: ?[]?Match = null;
                if (groups) |g| {
                    groups_slice = try self.allocator.dupe(?Match, g.items);
                }
                return Match{
                    .start = pos,
                    .end = end_pos,
                    .groups = groups_slice,
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

        // Use group-aware epsilon closure
        var visited = std.ArrayList(bool){};
        defer visited.deinit(self.allocator);
        try visited.resize(self.allocator, self.nfa.states.items.len);
        for (visited.items) |*v| v.* = false;

        try self.addEpsilonClosureRecWithGroups(&current_states, self.nfa.start_state, &visited, start_pos, input, groups);

        var pos = start_pos;
        while (pos <= input.len) {
            if (self.hasAcceptState(&current_states)) {
                return pos;
            }

            if (pos >= input.len) break;

            // Decode UTF-8 codepoint
            var decode_pos = pos;
            const codepoint = unicode.utf8DecodeNext(input, &decode_pos);
            if (codepoint) |cp| {
                try self.stepStatesWithGroupsUnicode(&current_states, &next_states, cp, decode_pos, input, groups);

                const tmp = current_states;
                current_states = next_states;
                next_states = tmp;
                next_states.clearRetainingCapacity();

                pos = decode_pos;
            } else {
                // Invalid UTF-8, skip byte
                pos += 1;
            }
        }

        if (self.hasAcceptState(&current_states)) {
            return pos;
        }

        return null;
    }

    fn addEpsilonClosure(self: *const NFAMatcher, states: *std.ArrayList(u32), state_id: u32, current_pos: usize, input: []const u8) RegexError!void {
        var visited = std.ArrayList(bool){};
        defer visited.deinit(self.allocator);

        try visited.resize(self.allocator, self.nfa.states.items.len);
        for (visited.items) |*v| v.* = false;

        try self.addEpsilonClosureRec(states, state_id, &visited, current_pos, input);
    }

    fn addEpsilonClosureRecWithGroups(self: *const NFAMatcher, states: *std.ArrayList(u32), state_id: u32, visited: *std.ArrayList(bool), current_pos: usize, input: []const u8, groups: ?*std.ArrayList(?Match)) RegexError!void {
        if (state_id >= self.nfa.states.items.len or visited.items[state_id]) {
            return;
        }

        visited.items[state_id] = true;
        try states.append(self.allocator, state_id);

        const state = &self.nfa.states.items[state_id];
        for (state.transitions.items) |transition| {
            switch (transition.condition) {
                .epsilon => try self.addEpsilonClosureRecWithGroups(states, transition.target, visited, current_pos, input, groups),
                .assert_start => {
                    if (current_pos == 0) {
                        try self.addEpsilonClosureRecWithGroups(states, transition.target, visited, current_pos, input, groups);
                    }
                },
                .assert_end => {
                    if (current_pos == input.len) {
                        try self.addEpsilonClosureRecWithGroups(states, transition.target, visited, current_pos, input, groups);
                    }
                },
                .group_start => |group_id| {
                    if (groups) |g| {
                        // Ensure groups array is large enough
                        while (g.items.len <= group_id) {
                            try g.append(self.allocator, null);
                        }
                        // Initialize or update group start
                        g.items[group_id] = Match{ .start = current_pos, .end = current_pos, .groups = null };
                    }
                    try self.addEpsilonClosureRecWithGroups(states, transition.target, visited, current_pos, input, groups);
                },
                .group_end => |group_id| {
                    if (groups) |g| {
                        // Ensure groups array is large enough
                        while (g.items.len <= group_id) {
                            try g.append(self.allocator, null);
                        }
                        // Update group end position
                        if (g.items[group_id]) |*existing| {
                            existing.end = current_pos;
                        }
                    }
                    try self.addEpsilonClosureRecWithGroups(states, transition.target, visited, current_pos, input, groups);
                },
                else => {},
            }
        }
    }

    fn addEpsilonClosureRec(self: *const NFAMatcher, states: *std.ArrayList(u32), state_id: u32, visited: *std.ArrayList(bool), current_pos: usize, input: []const u8) RegexError!void {
        return self.addEpsilonClosureRecWithGroups(states, state_id, visited, current_pos, input, null);
    }

    fn stepStates(self: *const NFAMatcher, current: *std.ArrayList(u32), next: *std.ArrayList(u32), char: u8, next_pos: usize, input: []const u8) RegexError!void {
        return self.stepStatesWithGroups(current, next, char, next_pos, input, null);
    }

    fn stepStatesWithGroups(self: *const NFAMatcher, current: *std.ArrayList(u32), next: *std.ArrayList(u32), char: u8, next_pos: usize, input: []const u8, groups: ?*std.ArrayList(?Match)) RegexError!void {
        const codepoint: u21 = char;
        return self.stepStatesWithGroupsUnicode(current, next, codepoint, next_pos, input, groups);
    }

    fn stepStatesWithGroupsUnicode(self: *const NFAMatcher, current: *std.ArrayList(u32), next: *std.ArrayList(u32), codepoint: u21, next_pos: usize, input: []const u8, groups: ?*std.ArrayList(?Match)) RegexError!void {
        for (current.items) |state_id| {
            const state = &self.nfa.states.items[state_id];
            for (state.transitions.items) |transition| {
                if (self.matchesTransitionUnicode(transition.condition, codepoint)) {
                    var visited = std.ArrayList(bool){};
                    defer visited.deinit(self.allocator);
                    try visited.resize(self.allocator, self.nfa.states.items.len);
                    for (visited.items) |*v| v.* = false;

                    try self.addEpsilonClosureRecWithGroups(next, transition.target, &visited, next_pos, input, groups);
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
                const codepoint: u21 = char;
                return char_class.matches(codepoint);
            },
            .assert_start, .assert_end => return false,
            .group_start, .group_end => return false, // Group transitions don't consume characters
        }
    }

    fn matchesTransitionUnicode(self: *const NFAMatcher, condition: NFA.TransitionCondition, codepoint: u21) bool {
        _ = self;
        switch (condition) {
            .epsilon => return false,
            .char => |c| return c == codepoint and codepoint <= 127, // ASCII only for char
            .any_char => return codepoint != '\n',
            .char_class => |*char_class| {
                return char_class.matches(codepoint);
            },
            .assert_start, .assert_end => return false,
            .group_start, .group_end => return false, // Group transitions don't consume characters
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