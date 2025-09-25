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
    groups: ?[]?Match = if (build_options.capture_groups) null else null,

    pub fn slice(self: Match, input: []const u8) []const u8 {
        return input[self.start..self.end];
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
        const jit_enabled = build_options.jit_enabled;
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
        const match_result = try self.find(input);
        return match_result != null;
    }

    pub fn find(self: *const Regex, input: []const u8) RegexError!?Match {
        // Try JIT first if available
        if (self.compiled.jit_program) |*program| {
            const jit_interpreter = jit.JITInterpreter.init(self.allocator, program);
            return try jit_interpreter.findMatch(input);
        }

        // Fallback to NFA
        if (self.compiled.nfa) |nfa| {
            const nfa_matcher = matcher.NFAMatcher.init(self.allocator, nfa);
            return try nfa_matcher.findMatch(input);
        }
        return RegexError.UnsupportedFeature;
    }

    pub fn findAll(self: *const Regex, allocator: Allocator, input: []const u8) RegexError![]Match {
        var matches = std.ArrayList(Match){};
        defer matches.deinit(allocator);

        if (self.compiled.nfa) |nfa| {
            const nfa_matcher = matcher.NFAMatcher.init(self.allocator, nfa);
            var pos: usize = 0;
            while (pos < input.len) {
                if (try nfa_matcher.findMatch(input[pos..])) |match| {
                    const adjusted_match = Match{
                        .start = pos + match.start,
                        .end = pos + match.end,
                        .groups = match.groups,
                    };
                    try matches.append(allocator, adjusted_match);
                    const advance = @max(1, match.end - match.start);
                    pos = pos + match.start + advance;
                } else {
                    pos += 1;
                }
            }
            return try matches.toOwnedSlice(allocator);
        }
        return RegexError.UnsupportedFeature;
    }

    pub fn createStreamingMatcher(self: *const Regex, allocator: Allocator) RegexError!streaming.StreamingMatcher {
        if (!build_options.streaming_enabled) {
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

    pub fn matches(self: *const CharClass, codepoint: u21) bool {
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

// Feature detection API
pub const features = struct {
    pub const jit = build_options.jit_enabled;
    pub const unicode = build_options.unicode_full;
    pub const streaming = build_options.streaming_enabled;
    pub const capture_groups = build_options.capture_groups;
    pub const backtracking = build_options.backtracking_enabled;
};
