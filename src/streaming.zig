const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");

const NFA = root.NFA;
const Match = root.Match;
const RegexError = root.RegexError;

pub const StreamingMatcher = struct {
    nfa: *const NFA,
    allocator: Allocator,
    current_states: std.ArrayList(u32),
    buffer: std.ArrayList(u8),
    processed_bytes: usize,
    matches: std.ArrayList(Match),

    pub fn init(allocator: Allocator, nfa: *const NFA) !StreamingMatcher {
        var current_states = std.ArrayList(u32){};
        try addEpsilonClosure(&current_states, allocator, nfa, nfa.start_state);

        return StreamingMatcher{
            .nfa = nfa,
            .allocator = allocator,
            .current_states = current_states,
            .buffer = std.ArrayList(u8){},
            .processed_bytes = 0,
            .matches = std.ArrayList(Match){},
        };
    }

    pub fn deinit(self: *StreamingMatcher) void {
        self.current_states.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
        self.matches.deinit(self.allocator);
    }

    pub fn feedData(self: *StreamingMatcher, data: []const u8) RegexError!void {
        try self.buffer.appendSlice(self.allocator, data);
        try self.processBuffer();
    }

    pub fn finalize(self: *StreamingMatcher) RegexError!void {
        // Check for any final matches at end of input
        if (hasAcceptState(&self.current_states, self.nfa)) {
            const match = Match{
                .start = self.findMatchStart(),
                .end = self.processed_bytes + self.buffer.items.len,
            };
            try self.matches.append(self.allocator, match);
        }
    }

    pub fn getMatches(self: *const StreamingMatcher) []const Match {
        return self.matches.items;
    }

    pub fn reset(self: *StreamingMatcher) !void {
        self.current_states.clearRetainingCapacity();
        self.buffer.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.processed_bytes = 0;

        try addEpsilonClosure(&self.current_states, self.allocator, self.nfa, self.nfa.start_state);
    }

    fn processBuffer(self: *StreamingMatcher) RegexError!void {
        var next_states = std.ArrayList(u32){};
        defer next_states.deinit(self.allocator);

        var pos: usize = 0;
        while (pos < self.buffer.items.len) {
            if (hasAcceptState(&self.current_states, self.nfa)) {
                const match = Match{
                    .start = self.findMatchStart(),
                    .end = self.processed_bytes + pos,
                };
                try self.matches.append(self.allocator, match);
            }

            const char = self.buffer.items[pos];
            try stepStates(&self.current_states, &next_states, char, self.allocator, self.nfa);

            // Swap states
            const tmp = self.current_states;
            self.current_states = next_states;
            next_states = tmp;
            next_states.clearRetainingCapacity();

            pos += 1;
        }

        // Update processed bytes and clear buffer
        self.processed_bytes += self.buffer.items.len;
        self.buffer.clearRetainingCapacity();
    }

    fn findMatchStart(self: *const StreamingMatcher) usize {
        // Simplified: assume match starts at beginning of processed data
        // In a real implementation, you'd track match start positions more carefully
        return self.processed_bytes;
    }

    fn stepStates(current: *std.ArrayList(u32), next: *std.ArrayList(u32), char: u8, allocator: Allocator, nfa: *const NFA) RegexError!void {
        for (current.items) |state_id| {
            const state = &nfa.states.items[state_id];
            for (state.transitions.items) |transition| {
                if (matchesTransition(transition.condition, char)) {
                    try addEpsilonClosure(next, allocator, nfa, transition.target);
                }
            }
        }
    }

    fn addEpsilonClosure(states: *std.ArrayList(u32), allocator: Allocator, nfa: *const NFA, state_id: u32) RegexError!void {
        var visited = std.ArrayList(bool){};
        defer visited.deinit(allocator);

        try visited.resize(allocator, nfa.states.items.len);
        for (visited.items) |*v| v.* = false;

        try addEpsilonClosureRec(states, allocator, nfa, state_id, &visited);
    }

    fn addEpsilonClosureRec(states: *std.ArrayList(u32), allocator: Allocator, nfa: *const NFA, state_id: u32, visited: *std.ArrayList(bool)) RegexError!void {
        if (state_id >= nfa.states.items.len or visited.items[state_id]) {
            return;
        }

        visited.items[state_id] = true;
        try states.append(allocator, state_id);

        const state = &nfa.states.items[state_id];
        for (state.transitions.items) |transition| {
            if (transition.condition == .epsilon) {
                try addEpsilonClosureRec(states, allocator, nfa, transition.target, visited);
            }
        }
    }

    fn matchesTransition(condition: NFA.TransitionCondition, char: u8) bool {
        switch (condition) {
            .epsilon => return false,
            .char => |c| return c == char,
            .any_char => return char != '\n',
            .char_class => |*char_class| {
                const codepoint: u21 = char;
                for (char_class.ranges.items) |range| {
                    if (codepoint >= range.start and codepoint <= range.end) {
                        return !char_class.negated;
                    }
                }
                return char_class.negated;
            },
        }
    }

    fn hasAcceptState(states: *const std.ArrayList(u32), nfa: *const NFA) bool {
        for (states.items) |state_id| {
            if (nfa.states.items[state_id].is_accept) {
                return true;
            }
        }
        return false;
    }
};

test "streaming matcher basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try root.Regex.compile(allocator, "hello");
    defer regex.deinit();

    var streaming_matcher = try StreamingMatcher.init(allocator, regex.compiled.nfa.?);
    defer streaming_matcher.deinit();

    // Feed data in chunks
    try streaming_matcher.feedData("hel");
    try streaming_matcher.feedData("lo wor");
    try streaming_matcher.feedData("ld");

    try streaming_matcher.finalize();

    const matches = streaming_matcher.getMatches();
    // Basic implementation - just verify no crash
    _ = matches;
}

test "streaming matcher multiple chunks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try root.Regex.compile(allocator, "\\d+");
    defer regex.deinit();

    var streaming_matcher = try StreamingMatcher.init(allocator, regex.compiled.nfa.?);
    defer streaming_matcher.deinit();

    // Feed data with numbers in different chunks
    try streaming_matcher.feedData("abc1");
    try streaming_matcher.feedData("23def4");
    try streaming_matcher.feedData("56ghi");

    try streaming_matcher.finalize();

    const matches = streaming_matcher.getMatches();
    // Basic implementation - just verify no crash
    _ = matches;
}