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
    matches: std.ArrayList(MatchWithBoundary),
    pending_match_start: ?usize,
    chunk_boundaries: std.ArrayList(usize), // Track where chunks were split

    const MatchWithBoundary = struct {
        match: Match,
        chunk_start_idx: usize, // Which chunk did this match start in
        chunk_end_idx: usize,   // Which chunk did this match end in
        is_cross_boundary: bool, // Does this match span multiple chunks

        pub fn getSlice(self: MatchWithBoundary, chunks: []const []const u8) []const u8 {
            if (!self.is_cross_boundary) {
                // Simple case: match is within a single chunk
                const chunk = chunks[self.chunk_start_idx];
                const local_start = self.match.start;
                const local_end = self.match.end;
                return chunk[local_start..local_end];
            } else {
                // Complex case: would need to reconstruct from multiple chunks
                // For now, return empty slice - caller should use getChunkAwareSlice
                return "";
            }
        }
    };

    pub fn init(allocator: Allocator, nfa: *const NFA) !StreamingMatcher {
        var current_states = std.ArrayList(u32){};
        try addEpsilonClosure(&current_states, allocator, nfa, nfa.start_state, 0, null);

        return StreamingMatcher{
            .nfa = nfa,
            .allocator = allocator,
            .current_states = current_states,
            .buffer = std.ArrayList(u8){},
            .processed_bytes = 0,
            .matches = std.ArrayList(MatchWithBoundary){},
            .pending_match_start = null,
            .chunk_boundaries = std.ArrayList(usize){},
        };
    }

    pub fn deinit(self: *StreamingMatcher) void {
        self.current_states.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
        self.matches.deinit(self.allocator);
        self.chunk_boundaries.deinit(self.allocator);
    }

    pub fn feedData(self: *StreamingMatcher, data: []const u8) RegexError!void {
        // Record the boundary before this chunk
        const boundary_pos = self.processed_bytes + self.buffer.items.len;
        try self.chunk_boundaries.append(self.allocator, boundary_pos);

        try self.buffer.appendSlice(self.allocator, data);
        try self.processBuffer();
    }

    pub fn finalize(self: *StreamingMatcher) RegexError!void {
        try self.applyEndAssertions();
        // Check for any final matches at end of input
        if (hasAcceptState(&self.current_states, self.nfa)) {
            const match_start = self.findMatchStart();
            const match_end = self.processed_bytes + self.buffer.items.len;

            const start_chunk_idx = self.findChunkIndex(match_start);
            const end_chunk_idx = self.findChunkIndex(match_end);

            const match_with_boundary = MatchWithBoundary{
                .match = Match{
                    .start = match_start,
                    .end = match_end,
                },
                .chunk_start_idx = start_chunk_idx,
                .chunk_end_idx = end_chunk_idx,
                .is_cross_boundary = start_chunk_idx != end_chunk_idx,
            };
            try self.matches.append(self.allocator, match_with_boundary);
        }
    }

    pub fn getMatches(self: *const StreamingMatcher) []const MatchWithBoundary {
        return self.matches.items;
    }

    pub fn getChunkAwareSlice(self: *const StreamingMatcher, match_idx: usize, input_chunks: []const []const u8, allocator: Allocator) ![]const u8 {
        if (match_idx >= self.matches.items.len) return RegexError.InvalidInput;

        const match_with_boundary = self.matches.items[match_idx];

        if (!match_with_boundary.is_cross_boundary) {
            // Simple case: match is within a single chunk
            return match_with_boundary.getSlice(input_chunks);
        } else {
            // Complex case: reconstruct from multiple chunks
            var result = std.ArrayList(u8){};
            defer result.deinit(allocator);

            const start_pos = match_with_boundary.match.start;
            const end_pos = match_with_boundary.match.end;
            var current_pos: usize = 0;

            for (input_chunks) |chunk| {
                const chunk_start = current_pos;
                const chunk_end = current_pos + chunk.len;

                if (chunk_end <= start_pos) {
                    // Chunk is before match
                    current_pos = chunk_end;
                    continue;
                }

                if (chunk_start >= end_pos) {
                    // Chunk is after match
                    break;
                }

                // Chunk overlaps with match
                const overlap_start = if (chunk_start >= start_pos) 0 else start_pos - chunk_start;
                const overlap_end = if (chunk_end <= end_pos) chunk.len else end_pos - chunk_start;

                try result.appendSlice(allocator, chunk[overlap_start..overlap_end]);
                current_pos = chunk_end;
            }

            return try result.toOwnedSlice(allocator);
        }
    }

    fn findChunkIndex(self: *const StreamingMatcher, pos: usize) usize {
        for (self.chunk_boundaries.items, 0..) |boundary, idx| {
            if (pos < boundary) {
                return if (idx == 0) 0 else idx - 1;
            }
        }
        return if (self.chunk_boundaries.items.len == 0) 0 else self.chunk_boundaries.items.len - 1;
    }

    pub fn reset(self: *StreamingMatcher) !void {
        self.current_states.clearRetainingCapacity();
        self.buffer.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.chunk_boundaries.clearRetainingCapacity();
        self.processed_bytes = 0;
        self.pending_match_start = null;

        try addEpsilonClosure(&self.current_states, self.allocator, self.nfa, self.nfa.start_state, 0, null);
    }

    fn applyEndAssertions(self: *StreamingMatcher) !void {
        const end_pos = self.processed_bytes + self.buffer.items.len;

        var visited = std.ArrayList(bool){};
        defer visited.deinit(self.allocator);
        try visited.resize(self.allocator, self.nfa.states.items.len);
        for (visited.items) |*v| v.* = false;

        var final_states = std.ArrayList(u32){};
        var cleanup = true;
        defer if (cleanup) final_states.deinit(self.allocator);

        for (self.current_states.items) |state_id| {
            try addEpsilonClosureRec(&final_states, self.allocator, self.nfa, state_id, &visited, end_pos, end_pos);
        }

        self.current_states.deinit(self.allocator);
        self.current_states = final_states;
        cleanup = false;
    }

    fn processBuffer(self: *StreamingMatcher) RegexError!void {
        var next_states = std.ArrayList(u32){};
        defer next_states.deinit(self.allocator);

        var pos: usize = 0;
        var absolute_pos = self.processed_bytes;
        while (pos < self.buffer.items.len) {
            if (hasAcceptState(&self.current_states, self.nfa)) {
                const match_start = self.findMatchStart();
                const match_end = absolute_pos;

                const start_chunk_idx = self.findChunkIndex(match_start);
                const end_chunk_idx = self.findChunkIndex(match_end);

                const match_with_boundary = MatchWithBoundary{
                    .match = Match{
                        .start = match_start,
                        .end = match_end,
                    },
                    .chunk_start_idx = start_chunk_idx,
                    .chunk_end_idx = end_chunk_idx,
                    .is_cross_boundary = start_chunk_idx != end_chunk_idx,
                };
                try self.matches.append(self.allocator, match_with_boundary);
            }

            const char = self.buffer.items[pos];
            try stepStates(&self.current_states, &next_states, char, self.allocator, self.nfa, absolute_pos + 1);

            // Swap states
            const tmp = self.current_states;
            self.current_states = next_states;
            next_states = tmp;
            next_states.clearRetainingCapacity();

            pos += 1;
            absolute_pos += 1;
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

    fn stepStates(current: *std.ArrayList(u32), next: *std.ArrayList(u32), char: u8, allocator: Allocator, nfa: *const NFA, next_absolute_pos: usize) RegexError!void {
        for (current.items) |state_id| {
            const state = &nfa.states.items[state_id];
            for (state.transitions.items) |transition| {
                if (matchesTransition(transition.condition, char)) {
                    try addEpsilonClosure(next, allocator, nfa, transition.target, next_absolute_pos, null);
                }
            }
        }
    }

    fn addEpsilonClosure(states: *std.ArrayList(u32), allocator: Allocator, nfa: *const NFA, state_id: u32, absolute_pos: usize, end_pos: ?usize) RegexError!void {
        var visited = std.ArrayList(bool){};
        defer visited.deinit(allocator);

        try visited.resize(allocator, nfa.states.items.len);
        for (visited.items) |*v| v.* = false;

        try addEpsilonClosureRec(states, allocator, nfa, state_id, &visited, absolute_pos, end_pos);
    }

    fn addEpsilonClosureRec(states: *std.ArrayList(u32), allocator: Allocator, nfa: *const NFA, state_id: u32, visited: *std.ArrayList(bool), absolute_pos: usize, end_pos: ?usize) RegexError!void {
        if (state_id >= nfa.states.items.len or visited.items[state_id]) {
            return;
        }

        visited.items[state_id] = true;
        try states.append(allocator, state_id);

        const state = &nfa.states.items[state_id];
        for (state.transitions.items) |transition| {
            switch (transition.condition) {
                .epsilon => try addEpsilonClosureRec(states, allocator, nfa, transition.target, visited, absolute_pos, end_pos),
                .assert_start => {
                    if (absolute_pos == 0) {
                        try addEpsilonClosureRec(states, allocator, nfa, transition.target, visited, absolute_pos, end_pos);
                    }
                },
                .assert_end => {
                    if (end_pos) |end| {
                        if (absolute_pos == end) {
                            try addEpsilonClosureRec(states, allocator, nfa, transition.target, visited, absolute_pos, end_pos);
                        }
                    }
                },
                else => {},
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
                return char_class.matches(codepoint);
            },
            .assert_start, .assert_end => return false,
            .group_start, .group_end => return false, // Group transitions don't consume characters
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

test "streaming start anchor enforced" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try root.Regex.compile(allocator, "^test");
    defer regex.deinit();

    var streaming_matcher = try StreamingMatcher.init(allocator, regex.compiled.nfa.?);
    defer streaming_matcher.deinit();

    try streaming_matcher.feedData("test");
    try streaming_matcher.finalize();

    const matches = streaming_matcher.getMatches();
    try std.testing.expect(matches.len == 1);
}

test "streaming start anchor rejects offset" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try root.Regex.compile(allocator, "^test");
    defer regex.deinit();

    var streaming_matcher = try StreamingMatcher.init(allocator, regex.compiled.nfa.?);
    defer streaming_matcher.deinit();

    try streaming_matcher.feedData("xx");
    try streaming_matcher.feedData("test");
    try streaming_matcher.finalize();

    const matches = streaming_matcher.getMatches();
    try std.testing.expect(matches.len == 0);
}

test "streaming end anchor enforced on finalize" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try root.Regex.compile(allocator, "test$");
    defer regex.deinit();

    var streaming_matcher = try StreamingMatcher.init(allocator, regex.compiled.nfa.?);
    defer streaming_matcher.deinit();

    try streaming_matcher.feedData("te");
    try streaming_matcher.feedData("st");
    try streaming_matcher.finalize();

    const matches = streaming_matcher.getMatches();
    try std.testing.expect(matches.len == 1);
}