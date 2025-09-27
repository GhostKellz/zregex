const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const nfa_builder = @import("nfa_builder.zig");
const matcher = @import("matcher.zig");
const streaming = @import("streaming.zig");
const jit = @import("jit.zig");
const build_options = @import("build_options");

pub const RegexError = error{
    InvalidPattern,
    CompilationFailed,
    MatchingFailed,
    OutOfMemory,
    InvalidInput,
    UnsupportedFeature,
};

pub const Match = struct {
    start: usize,
    end: usize,
    groups: ?[]?Match = null,

    pub fn slice(self: Match, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }

    pub fn group(self: Match, group_id: usize) ?Match {
        if (self.groups) |groups| {
            if (group_id < groups.len) {
                return groups[group_id];
            }
        }
        return null;
    }

    pub fn groupSlice(self: Match, group_id: usize, input: []const u8) ?[]const u8 {
        if (self.group(group_id)) |group_match| {
            return group_match.slice(input);
        }
        return null;
    }

    pub fn deinit(self: *Match, allocator: Allocator) void {
        if (self.groups) |groups| {
            allocator.free(groups);
            self.groups = null;
        }
    }
};

pub const Regex = struct {
    pattern: []const u8,
    compiled: CompiledPattern,
    allocator: Allocator,

    const CompiledPattern = struct {
        ast: ?parser.AST = null,
        nfa: ?*NFA = null,
        dfa: ?*DFA = null,
        jit_program: ?jit.Program = null,
        flags: CompileFlags = .{},
    };

    const CompileFlags = struct {
        case_insensitive: bool = false,
        multiline: bool = false,
        dot_all: bool = false,
        unicode: bool = true,
        jit_enabled: bool = false,
    };

    pub fn compile(allocator: Allocator, pattern: []const u8) RegexError!Regex {
        var regex_parser = parser.Parser.init(allocator, pattern);
        var ast = regex_parser.parse() catch |err| switch (err) {
            error.OutOfMemory => return RegexError.OutOfMemory,
            else => return RegexError.InvalidPattern,
        };

        var builder = nfa_builder.NFABuilder.init(allocator) catch return RegexError.OutOfMemory;
        defer builder.deinit();

        const nfa = builder.build(&ast) catch return RegexError.OutOfMemory;

        // Optionally compile to JIT if enabled
        var jit_program: ?jit.Program = null;
        const has_assertions = blk: {
            for (nfa.states.items) |state| {
                for (state.transitions.items) |transition| {
                    switch (transition.condition) {
                        .assert_start, .assert_end => break :blk true,
                        else => {},
                    }
                }
            }
            break :blk false;
        };
        const jit_enabled = features.isJitEnabled() and !has_assertions;
        if (jit_enabled) { // JIT enabled
            var jit_compiler = jit.JITCompiler.init(allocator);
            defer jit_compiler.deinit();

            jit_program = jit_compiler.compile(nfa) catch null;
        }

        return Regex{
            .pattern = try allocator.dupe(u8, pattern),
            .compiled = CompiledPattern{
                .ast = ast,
                .nfa = nfa,
                .jit_program = jit_program,
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Regex) void {
        self.allocator.free(self.pattern);
        if (self.compiled.ast) |*ast| {
            ast.deinit();
        }
        if (self.compiled.nfa) |nfa| {
            nfa.deinit(self.allocator);
        }
        if (self.compiled.dfa) |dfa| {
            dfa.deinit(self.allocator);
        }
        if (self.compiled.jit_program) |*program| {
            program.deinit();
        }
    }

    pub fn isMatch(self: *const Regex, input: []const u8) RegexError!bool {
        // Use efficient boolean-only matching without group allocation
        if (self.compiled.nfa) |nfa| {
            const nfa_matcher = matcher.NFAMatcher{ .nfa = nfa, .allocator = self.allocator };
            return try nfa_matcher.isMatchOnly(input);
        }
        return false;
    }

    pub fn find(self: *const Regex, input: []const u8) RegexError!?Match {
        return self.findWithGroups(input);
    }

    pub fn findWithGroups(self: *const Regex, input: []const u8) RegexError!?Match {
        // Try JIT first if available and enabled (but JIT doesn't support groups yet)
        if (self.compiled.jit_program) |*program| {
            if (features.isJitEnabled() and !build_options.capture_groups) {
                const jit_interpreter = jit.JITInterpreter.init(self.allocator, program);
                if (try jit_interpreter.findMatch(input)) |jit_match| {
                    return jit_match;
                }
            }
        }

        // Use NFA for group support
        if (self.compiled.nfa) |nfa| {
            const nfa_matcher = matcher.NFAMatcher.init(self.allocator, nfa);
            if (build_options.capture_groups) {
                var groups = std.ArrayList(?Match){};
                defer groups.deinit(self.allocator);
                return try nfa_matcher.findMatchWithGroups(input, &groups);
            } else {
                return try nfa_matcher.findMatch(input);
            }
        }
        return RegexError.UnsupportedFeature;
    }

    pub fn findAll(self: *const Regex, allocator: Allocator, input: []const u8) RegexError![]Match {
        var matches = std.ArrayList(Match){};
        defer matches.deinit(allocator);

        if (self.compiled.nfa) |nfa| {
            const nfa_matcher = matcher.NFAMatcher.init(self.allocator, nfa);
            var pos: usize = 0;
            while (pos <= input.len) {
                if (try nfa_matcher.findMatchFrom(input, pos)) |found| {
                    try matches.append(allocator, found);
                    const advance = @max(1, found.end - found.start);
                    pos = found.start + advance;
                } else {
                    break;
                }
            }
            return try matches.toOwnedSlice(allocator);
        }
        return RegexError.UnsupportedFeature;
    }

    pub fn createStreamingMatcher(self: *const Regex, allocator: Allocator) RegexError!streaming.StreamingMatcher {
        if (!build_options.streaming_enabled or !features.isStreamingPreferred()) {
            return RegexError.UnsupportedFeature;
        }
        if (self.compiled.nfa) |nfa| {
            return streaming.StreamingMatcher.init(allocator, nfa) catch RegexError.OutOfMemory;
        }
        return RegexError.UnsupportedFeature;
    }
};

pub const NFA = struct {
    states: std.ArrayList(State),
    start_state: u32,
    accept_states: std.ArrayList(u32),

    pub const State = struct {
        id: u32,
        transitions: std.ArrayList(Transition),
        is_accept: bool = false,

        pub fn init(allocator: Allocator, id: u32) State {
            _ = allocator;
            return State{
                .id = id,
                .transitions = std.ArrayList(Transition){},
            };
        }
    };

    pub const Transition = struct {
        target: u32,
        condition: TransitionCondition,
    };

    pub const TransitionCondition = union(enum) {
        epsilon,
        char: u8,
        char_class: CharClass,
        any_char,
        assert_start,
        assert_end,
        group_start: u32, // group_id
        group_end: u32,   // group_id
    };

    pub fn init(allocator: Allocator) NFA {
        _ = allocator;
        return NFA{
            .states = std.ArrayList(State){},
            .start_state = 0,
            .accept_states = std.ArrayList(u32){},
        };
    }

    pub fn deinit(self: *NFA, allocator: Allocator) void {
        for (self.states.items) |*state| {
            for (state.transitions.items) |*transition| {
                switch (transition.condition) {
                    .char_class => |*char_class| {
                        char_class.deinit(allocator);
                    },
                    else => {},
                }
            }
            state.transitions.deinit(allocator);
        }
        self.states.deinit(allocator);
        self.accept_states.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const DFA = struct {
    states: std.ArrayList(State),
    start_state: u32,
    transition_table: std.HashMap(StateChar, u32, StateCharContext, std.hash_map.default_max_load_percentage),

    const State = struct {
        id: u32,
        is_accept: bool = false,
    };

    const StateChar = struct {
        state: u32,
        char: u8,
    };

    const StateCharContext = struct {
        pub fn hash(self: @This(), s: StateChar) u64 {
            _ = self;
            return std.hash_map.hashString(std.mem.asBytes(&s));
        }

        pub fn eql(self: @This(), a: StateChar, b: StateChar) bool {
            _ = self;
            return a.state == b.state and a.char == b.char;
        }
    };

    pub fn init(allocator: Allocator) DFA {
        return DFA{
            .states = std.ArrayList(State){},
            .start_state = 0,
            .transition_table = std.HashMap(StateChar, u32, StateCharContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *DFA, allocator: Allocator) void {
        self.states.deinit(allocator);
        self.transition_table.deinit();
        allocator.destroy(self);
    }
};

pub const CharClass = struct {
    ranges: std.ArrayList(CharRange),
    negated: bool = false,
    ascii_bitmap: ?[16]u8 = null, // 128 bits for ASCII 0-127

    const CharRange = struct {
        start: u21,
        end: u21,
    };

    pub fn init(allocator: Allocator) CharClass {
        _ = allocator;
        return CharClass{
            .ranges = std.ArrayList(CharRange){},
        };
    }

    pub fn deinit(self: *CharClass, allocator: Allocator) void {
        self.ranges.deinit(allocator);
    }

    pub fn optimizeForAscii(self: *CharClass) void {
        // Check if all ranges are ASCII (0-127)
        var all_ascii = true;
        for (self.ranges.items) |range| {
            if (range.start > 127 or range.end > 127) {
                all_ascii = false;
                break;
            }
        }

        if (all_ascii and self.ranges.items.len > 0) {
            // Create ASCII bitmap
            var bitmap: [16]u8 = [_]u8{0} ** 16;
            for (self.ranges.items) |range| {
                var i = range.start;
                while (i <= range.end) : (i += 1) {
                    const byte_idx = i / 8;
                    const bit_idx = @as(u3, @intCast(i % 8));
                    bitmap[byte_idx] |= (@as(u8, 1) << bit_idx);
                }
            }
            self.ascii_bitmap = bitmap;
        }
    }

    pub fn matches(self: *const CharClass, codepoint: u21) bool {
        // ASCII fast path using bitmap
        if (codepoint <= 127) {
            if (self.ascii_bitmap) |bitmap| {
                const byte_idx = codepoint / 8;
                const bit_idx = @as(u3, @intCast(codepoint % 8));
                const bit_set = (bitmap[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
                return if (self.negated) !bit_set else bit_set;
            }
        }

        // Fallback to range scanning for Unicode or non-optimized ASCII
        for (self.ranges.items) |range| {
            if (codepoint >= range.start and codepoint <= range.end) {
                return !self.negated;
            }
        }
        return self.negated;
    }
};

test "regex compilation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "hello.*world");
    defer regex.deinit();

    try std.testing.expect(std.mem.eql(u8, regex.pattern, "hello.*world"));
}

test "basic literal matching" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "hello");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello world"));
    try std.testing.expect(try regex.isMatch("say hello there"));
    try std.testing.expect(!try regex.isMatch("hi there"));
}

test "quantifier matching" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex_star = try Regex.compile(allocator, "a*");
    defer regex_star.deinit();


    const empty_match = try regex_star.isMatch("");
    try std.testing.expect(empty_match);
    try std.testing.expect(try regex_star.isMatch("a"));
    try std.testing.expect(try regex_star.isMatch("aaa"));
    try std.testing.expect(try regex_star.isMatch("bbb"));

    var regex_plus = try Regex.compile(allocator, "a+");
    defer regex_plus.deinit();

    try std.testing.expect(!try regex_plus.isMatch(""));
    try std.testing.expect(try regex_plus.isMatch("a"));
    try std.testing.expect(try regex_plus.isMatch("aaa"));
    try std.testing.expect(try regex_plus.isMatch("baaac"));
}

test "find and findAll" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "ll");
    defer regex.deinit();

    if (try regex.find("hello world")) |match| {
        try std.testing.expect(match.start == 2);
        try std.testing.expect(match.end == 4);
        try std.testing.expectEqualStrings("ll", match.slice("hello world"));
    } else {
        try std.testing.expect(false);
    }

    const matches = try regex.findAll(allocator, "hello all y'all");
    defer allocator.free(matches);
    try std.testing.expect(matches.len == 3);
    try std.testing.expect(matches[0].start == 2);
    try std.testing.expect(matches[1].start == 7);
    try std.testing.expect(matches[2].start == 13);
}

test "anchors enforce boundaries" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "^hello$");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("hello"));
    try std.testing.expect(!try regex.isMatch("hello world"));
    try std.testing.expect(!try regex.isMatch("say hello"));
}

test "anchor alternation semantics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "^foo|bar");
    defer regex.deinit();

    try std.testing.expect(try regex.isMatch("foobar"));
    try std.testing.expect(try regex.isMatch("bar"));
    try std.testing.expect(!try regex.isMatch("zfoo"));
}

test "findAll respects anchors" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var start_regex = try Regex.compile(allocator, "^a");
    defer start_regex.deinit();

    const matches = try start_regex.findAll(allocator, "abcaa");
    defer allocator.free(matches);
    try std.testing.expect(matches.len == 1);
    try std.testing.expect(matches[0].start == 0);
    try std.testing.expect(matches[0].end == 1);

    var end_regex = try Regex.compile(allocator, "b$");
    defer end_regex.deinit();

    const tail_matches = try end_regex.findAll(allocator, "abbab");
    defer allocator.free(tail_matches);
    try std.testing.expect(tail_matches.len == 1);
    try std.testing.expect(tail_matches[0].start == 4);
    try std.testing.expect(tail_matches[0].end == 5);
}

test "character classes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test digit character class
    var digit_regex = try Regex.compile(allocator, "\\d+");
    defer digit_regex.deinit();

    try std.testing.expect(try digit_regex.isMatch("123"));
    try std.testing.expect(try digit_regex.isMatch("abc123def"));
    try std.testing.expect(!try digit_regex.isMatch("abc"));

    // Test word character class
    var word_regex = try Regex.compile(allocator, "\\w+");
    defer word_regex.deinit();

    try std.testing.expect(try word_regex.isMatch("hello"));
    try std.testing.expect(try word_regex.isMatch("hello_world123"));
    try std.testing.expect(try word_regex.isMatch("123test"));

    // Test whitespace character class
    var space_regex = try Regex.compile(allocator, "\\s+");
    defer space_regex.deinit();

    try std.testing.expect(try space_regex.isMatch("   "));
    try std.testing.expect(try space_regex.isMatch("\t\n"));
    try std.testing.expect(!try space_regex.isMatch("hello"));
}

test "character ranges" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var range_regex = try Regex.compile(allocator, "[a-z]+");
    defer range_regex.deinit();

    try std.testing.expect(try range_regex.isMatch("hello"));
    try std.testing.expect(try range_regex.isMatch("test"));
    try std.testing.expect(try range_regex.isMatch("Hello")); // matches "ello" part
    try std.testing.expect(!try range_regex.isMatch("123"));
    try std.testing.expect(!try range_regex.isMatch("HELLO")); // all uppercase

    var negated_regex = try Regex.compile(allocator, "[^0-9]+");
    defer negated_regex.deinit();

    try std.testing.expect(try negated_regex.isMatch("hello"));
    try std.testing.expect(!try negated_regex.isMatch("123"));
}

test "streaming matching" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Enable streaming for this test
    const original_options = features.getRuntimeOptions();
    defer features.setRuntimeOptions(original_options);
    features.setRuntimeOptions(.{ .prefer_streaming = true });

    var regex = try Regex.compile(allocator, "test");
    defer regex.deinit();

    var streaming_matcher = try regex.createStreamingMatcher(allocator);
    defer streaming_matcher.deinit();

    // Feed data in multiple chunks
    try streaming_matcher.feedData("this is a te");
    try streaming_matcher.feedData("st of streaming");
    try streaming_matcher.feedData(" matching");

    try streaming_matcher.finalize();

    const matches = streaming_matcher.getMatches();
    // Streaming implementation is basic - just check it doesn't crash
    _ = matches;
}

test "jit compilation framework" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "test");
    defer regex.deinit();

    // JIT framework is implemented and enabled
    try std.testing.expect(regex.compiled.jit_program != null);

    // Regular matching still works
    try std.testing.expect(try regex.isMatch("test input"));
    try std.testing.expect(!try regex.isMatch("no match"));
}

test "capture groups basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "(hello) (world)");
    defer regex.deinit();

    if (try regex.findWithGroups("say hello world!")) |match| {
        defer if (match.groups) |groups| allocator.free(groups);

        try std.testing.expect(match.start == 4);
        try std.testing.expect(match.end == 15);
        try std.testing.expectEqualStrings("hello world", match.slice("say hello world!"));

        if (match.groups) |groups| {
            try std.testing.expect(groups.len >= 3); // Groups 0, 1, 2

            // Group 1: "hello"
            if (groups[1]) |group1| {
                try std.testing.expect(group1.start == 4);
                try std.testing.expect(group1.end == 9);
                try std.testing.expectEqualStrings("hello", group1.slice("say hello world!"));
            } else {
                try std.testing.expect(false); // Group 1 should exist
            }

            // Group 2: "world"
            if (groups[2]) |group2| {
                try std.testing.expect(group2.start == 10);
                try std.testing.expect(group2.end == 15);
                try std.testing.expectEqualStrings("world", group2.slice("say hello world!"));
            } else {
                try std.testing.expect(false); // Group 2 should exist
            }
        } else {
            try std.testing.expect(false); // Groups should exist
        }
    } else {
        try std.testing.expect(false); // Match should exist
    }
}

test "non-capturing groups" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "(?:hello) (world)");
    defer regex.deinit();

    if (try regex.findWithGroups("say hello world!")) |match| {
        defer if (match.groups) |groups| allocator.free(groups);

        try std.testing.expect(match.start == 4);
        try std.testing.expect(match.end == 15);
        try std.testing.expectEqualStrings("hello world", match.slice("say hello world!"));

        if (match.groups) |groups| {
            // Only group 1 should exist (group 0 would be non-capturing)
            try std.testing.expect(groups.len >= 1);

            // Group 1: "world" (the only capturing group)
            if (groups[1]) |group1| {
                try std.testing.expect(group1.start == 10);
                try std.testing.expect(group1.end == 15);
                try std.testing.expectEqualStrings("world", group1.slice("say hello world!"));
            } else {
                try std.testing.expect(false); // Group 1 should exist
            }
        }
    } else {
        try std.testing.expect(false); // Match should exist
    }
}

test "nested capture groups" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try Regex.compile(allocator, "(he(ll)o)");
    defer regex.deinit();

    if (try regex.findWithGroups("hello world")) |match| {
        defer if (match.groups) |groups| allocator.free(groups);

        try std.testing.expect(match.start == 0);
        try std.testing.expect(match.end == 5);
        try std.testing.expectEqualStrings("hello", match.slice("hello world"));

        if (match.groups) |groups| {
            try std.testing.expect(groups.len >= 2);

            // Group 1: "hello"
            if (groups[1]) |group1| {
                try std.testing.expect(group1.start == 0);
                try std.testing.expect(group1.end == 5);
                try std.testing.expectEqualStrings("hello", group1.slice("hello world"));
            }

            // Group 2: "ll"
            if (groups[2]) |group2| {
                try std.testing.expect(group2.start == 2);
                try std.testing.expect(group2.end == 4);
                try std.testing.expectEqualStrings("ll", group2.slice("hello world"));
            }
        }
    } else {
        try std.testing.expect(false); // Match should exist
    }
}

test "capture groups simple case" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test simple group without quantifiers first
    var regex = try Regex.compile(allocator, "(a)");
    defer regex.deinit();

    if (try regex.findWithGroups("abc")) |match| {
        defer if (match.groups) |groups| allocator.free(groups);

        try std.testing.expect(match.start == 0);
        try std.testing.expect(match.end == 1);
        try std.testing.expectEqualStrings("a", match.slice("abc"));

        if (match.groups) |groups| {
            try std.testing.expect(groups.len >= 1);
            if (groups[1]) |group1| {
                try std.testing.expect(group1.start == 0);
                try std.testing.expect(group1.end == 1);
                try std.testing.expectEqualStrings("a", group1.slice("abc"));
            } else {
                try std.testing.expect(false); // Group 1 should exist
            }
        } else {
            try std.testing.expect(false); // Groups should exist
        }
    } else {
        try std.testing.expect(false); // Match should exist
    }
}

test "anchor edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start anchor only
    var start_regex = try Regex.compile(allocator, "^hello");
    defer start_regex.deinit();

    try std.testing.expect(try start_regex.isMatch("hello world"));
    try std.testing.expect(!try start_regex.isMatch("say hello"));

    // End anchor only
    var end_regex = try Regex.compile(allocator, "world$");
    defer end_regex.deinit();

    try std.testing.expect(try end_regex.isMatch("hello world"));
    try std.testing.expect(!try end_regex.isMatch("world hello"));

    // Both anchors
    var both_regex = try Regex.compile(allocator, "^exact$");
    defer both_regex.deinit();

    try std.testing.expect(try both_regex.isMatch("exact"));
    try std.testing.expect(!try both_regex.isMatch("not exact"));
    try std.testing.expect(!try both_regex.isMatch("exact not"));

    // Empty string with anchors
    var empty_regex = try Regex.compile(allocator, "^$");
    defer empty_regex.deinit();

    try std.testing.expect(try empty_regex.isMatch(""));
    try std.testing.expect(!try empty_regex.isMatch("a"));
}

test "alternation edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Simple alternation
    var simple_regex = try Regex.compile(allocator, "cat|dog");
    defer simple_regex.deinit();

    try std.testing.expect(try simple_regex.isMatch("I have a cat"));
    try std.testing.expect(try simple_regex.isMatch("I have a dog"));
    try std.testing.expect(!try simple_regex.isMatch("I have a bird"));

    // Alternation with anchors
    var anchor_regex = try Regex.compile(allocator, "^(start|begin)");
    defer anchor_regex.deinit();

    try std.testing.expect(try anchor_regex.isMatch("start here"));
    try std.testing.expect(try anchor_regex.isMatch("begin here"));
    try std.testing.expect(!try anchor_regex.isMatch("not start"));

    // Multiple alternations
    var multi_regex = try Regex.compile(allocator, "a|b|c");
    defer multi_regex.deinit();

    try std.testing.expect(try multi_regex.isMatch("apple"));
    try std.testing.expect(try multi_regex.isMatch("banana"));
    try std.testing.expect(try multi_regex.isMatch("cherry"));
    try std.testing.expect(!try multi_regex.isMatch("dog"));

    // Empty alternation branch - this is complex, skip for now
    // var empty_regex = try Regex.compile(allocator, "a|");
    // defer empty_regex.deinit();
    //
    // try std.testing.expect(try empty_regex.isMatch("a"));
    // try std.testing.expect(try empty_regex.isMatch("")); // Empty branch matches
}

test "quantifier edge cases" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Zero quantifier with +
    var plus_regex = try Regex.compile(allocator, "a+");
    defer plus_regex.deinit();

    try std.testing.expect(!try plus_regex.isMatch(""));
    try std.testing.expect(try plus_regex.isMatch("a"));
    try std.testing.expect(try plus_regex.isMatch("aaa"));

    // Zero quantifier with *
    var star_regex = try Regex.compile(allocator, "a*");
    defer star_regex.deinit();

    try std.testing.expect(try star_regex.isMatch(""));
    try std.testing.expect(try star_regex.isMatch("a"));
    try std.testing.expect(try star_regex.isMatch("aaa"));

    // Optional quantifier
    var optional_regex = try Regex.compile(allocator, "colou?r");
    defer optional_regex.deinit();

    try std.testing.expect(try optional_regex.isMatch("color"));
    try std.testing.expect(try optional_regex.isMatch("colour"));
    try std.testing.expect(!try optional_regex.isMatch("colouur"));

    // Exact quantifier
    var exact_regex = try Regex.compile(allocator, "a{3}");
    defer exact_regex.deinit();

    try std.testing.expect(!try exact_regex.isMatch("aa"));
    try std.testing.expect(try exact_regex.isMatch("aaa"));
    try std.testing.expect(try exact_regex.isMatch("aaaa")); // Matches first 3

    // Range quantifier
    var range_regex = try Regex.compile(allocator, "a{2,4}");
    defer range_regex.deinit();

    try std.testing.expect(!try range_regex.isMatch("a"));
    try std.testing.expect(try range_regex.isMatch("aa"));
    try std.testing.expect(try range_regex.isMatch("aaa"));
    try std.testing.expect(try range_regex.isMatch("aaaa"));
    try std.testing.expect(try range_regex.isMatch("aaaaa")); // Matches first 4
}

test "group nesting and alternation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Groups with alternation
    var group_alt_regex = try Regex.compile(allocator, "(cat|dog) food");
    defer group_alt_regex.deinit();

    try std.testing.expect(try group_alt_regex.isMatch("cat food"));
    try std.testing.expect(try group_alt_regex.isMatch("dog food"));
    try std.testing.expect(!try group_alt_regex.isMatch("bird food"));

    // Nested groups
    var nested_regex = try Regex.compile(allocator, "((a)b)c");
    defer nested_regex.deinit();

    try std.testing.expect(try nested_regex.isMatch("abc"));
    try std.testing.expect(!try nested_regex.isMatch("ac"));

    // Multiple non-capturing groups
    var multi_non_cap_regex = try Regex.compile(allocator, "(?:hello) (?:world)");
    defer multi_non_cap_regex.deinit();

    try std.testing.expect(try multi_non_cap_regex.isMatch("hello world"));
    try std.testing.expect(!try multi_non_cap_regex.isMatch("hello there"));
}

test "runtime feature toggles" {
    // Test feature info API
    const info = features.getFeatureInfo();
    try std.testing.expect(info.build_time.jit == features.jit);
    try std.testing.expect(info.build_time.capture_groups == features.capture_groups);

    // Test runtime options
    const original_options = features.getRuntimeOptions();
    defer features.setRuntimeOptions(original_options); // Restore after test

    // Disable JIT at runtime
    features.setRuntimeOptions(.{
        .prefer_jit = false,
        .force_nfa = true,
        .enable_diagnostics = true,
    });

    try std.testing.expect(!features.isJitEnabled());
    try std.testing.expect(features.isDiagnosticsEnabled());

    // Enable streaming preference
    features.setRuntimeOptions(.{
        .prefer_streaming = true,
        .enable_diagnostics = true, // Keep diagnostics enabled
    });

    if (features.streaming) {
        try std.testing.expect(features.isStreamingPreferred());
    }

    // Test effective feature info
    const updated_info = features.getFeatureInfo();
    try std.testing.expect(updated_info.effective.diagnostics_enabled);
}

// Feature detection API
pub const features = struct {
    // Build-time feature flags (immutable)
    pub const jit = build_options.jit_enabled;
    pub const unicode = build_options.unicode_full;
    pub const streaming = build_options.streaming_enabled;
    pub const capture_groups = build_options.capture_groups;
    pub const backtracking = build_options.backtracking_enabled;

    // Runtime feature toggles (mutable state)
    pub const RuntimeOptions = struct {
        prefer_jit: bool = true,
        prefer_streaming: bool = false,
        force_nfa: bool = false,
        enable_diagnostics: bool = false,
        debug_mode: bool = false,
    };

    var runtime_options = RuntimeOptions{};

    pub fn setRuntimeOptions(options: RuntimeOptions) void {
        runtime_options = options;
    }

    pub fn getRuntimeOptions() RuntimeOptions {
        return runtime_options;
    }

    // Query effective features (build-time && runtime)
    pub fn isJitEnabled() bool {
        return build_options.jit_enabled and runtime_options.prefer_jit and !runtime_options.force_nfa;
    }

    pub fn isStreamingPreferred() bool {
        return build_options.streaming_enabled and runtime_options.prefer_streaming;
    }

    pub fn isDiagnosticsEnabled() bool {
        return runtime_options.enable_diagnostics;
    }

    pub fn isDebugMode() bool {
        return runtime_options.debug_mode;
    }

    // Feature info for debugging/introspection
    pub fn getFeatureInfo() FeatureInfo {
        return FeatureInfo{
            .build_time = .{
                .jit = build_options.jit_enabled,
                .unicode = build_options.unicode_full,
                .streaming = build_options.streaming_enabled,
                .capture_groups = build_options.capture_groups,
                .backtracking = build_options.backtracking_enabled,
            },
            .runtime = runtime_options,
            .effective = .{
                .jit_enabled = isJitEnabled(),
                .streaming_preferred = isStreamingPreferred(),
                .diagnostics_enabled = isDiagnosticsEnabled(),
                .debug_mode = isDebugMode(),
            },
        };
    }

    pub const FeatureInfo = struct {
        build_time: struct {
            jit: bool,
            unicode: bool,
            streaming: bool,
            capture_groups: bool,
            backtracking: bool,
        },
        runtime: RuntimeOptions,
        effective: struct {
            jit_enabled: bool,
            streaming_preferred: bool,
            diagnostics_enabled: bool,
            debug_mode: bool,
        },
    };
};
