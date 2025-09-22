const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");

const NFA = root.NFA;
const Match = root.Match;
const RegexError = root.RegexError;

pub const Instruction = union(enum) {
    char: u8,
    char_class: struct {
        ranges: []const CharRange,
        negated: bool,
    },
    any_char,
    split: struct {
        target1: u32,
        target2: u32,
    },
    jump: u32,
    match_found,

    const CharRange = struct {
        start: u21,
        end: u21,
    };
};

pub const Program = struct {
    instructions: []Instruction,
    allocator: Allocator,

    pub fn deinit(self: *Program) void {
        for (self.instructions) |*inst| {
            switch (inst.*) {
                .char_class => |*cc| {
                    self.allocator.free(cc.ranges);
                },
                else => {},
            }
        }
        self.allocator.free(self.instructions);
    }
};

pub const JITCompiler = struct {
    allocator: Allocator,
    instructions: std.ArrayList(Instruction),

    pub fn init(allocator: Allocator) JITCompiler {
        return JITCompiler{
            .allocator = allocator,
            .instructions = std.ArrayList(Instruction){},
        };
    }

    pub fn deinit(self: *JITCompiler) void {
        self.instructions.deinit(self.allocator);
    }

    pub fn compile(self: *JITCompiler, nfa: *const NFA) !Program {
        self.instructions.clearRetainingCapacity();

        // Convert NFA to linear bytecode
        try self.compileNFA(nfa);

        const program = Program{
            .instructions = try self.instructions.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };

        return program;
    }

    fn compileNFA(self: *JITCompiler, nfa: *const NFA) !void {
        // Simple linear compilation - just process the start state and follow transitions
        var visited = std.ArrayList(bool){};
        defer visited.deinit(self.allocator);

        try visited.resize(self.allocator, nfa.states.items.len);
        for (visited.items) |*v| v.* = false;

        try self.compileStateRecursive(nfa, nfa.start_state, &visited);

        // Add final match instruction
        try self.instructions.append(self.allocator, .match_found);
    }

    fn compileStateRecursive(self: *JITCompiler, nfa: *const NFA, state_id: u32, visited: *std.ArrayList(bool)) !void {
        if (state_id >= nfa.states.items.len or visited.items[state_id]) {
            return;
        }

        visited.items[state_id] = true;
        const state = &nfa.states.items[state_id];

        if (state.is_accept) {
            try self.instructions.append(self.allocator, .match_found);
            return;
        }

        // For simplicity, just handle the first transition
        if (state.transitions.items.len > 0) {
            const transition = &state.transitions.items[0];
            switch (transition.condition) {
                .epsilon => {
                    // Follow epsilon transitions immediately
                    try self.compileStateRecursive(nfa, transition.target, visited);
                },
                .char => |c| {
                    try self.instructions.append(self.allocator, .{ .char = c });
                    try self.compileStateRecursive(nfa, transition.target, visited);
                },
                .any_char => {
                    try self.instructions.append(self.allocator, .any_char);
                    try self.compileStateRecursive(nfa, transition.target, visited);
                },
                .char_class => |*char_class| {
                    const ranges = try self.allocator.alloc(Instruction.CharRange, char_class.ranges.items.len);
                    for (char_class.ranges.items, 0..) |range, i| {
                        ranges[i] = .{ .start = range.start, .end = range.end };
                    }

                    try self.instructions.append(self.allocator, .{
                        .char_class = .{
                            .ranges = ranges,
                            .negated = char_class.negated,
                        },
                    });
                    try self.compileStateRecursive(nfa, transition.target, visited);
                },
            }
        }
    }
};

pub const JITInterpreter = struct {
    program: *const Program,
    allocator: Allocator,

    pub fn init(allocator: Allocator, program: *const Program) JITInterpreter {
        return JITInterpreter{
            .program = program,
            .allocator = allocator,
        };
    }

    pub fn findMatch(self: *const JITInterpreter, input: []const u8) RegexError!?Match {
        for (0..input.len + 1) |start_pos| {
            if (try self.executeAt(input, start_pos)) |end_pos| {
                return Match{
                    .start = start_pos,
                    .end = end_pos,
                };
            }
        }
        return null;
    }

    fn executeAt(self: *const JITInterpreter, input: []const u8, start_pos: usize) RegexError!?usize {
        var pc: u32 = 0; // Program counter
        var input_pos = start_pos;

        // Simple linear execution - no jumps, just sequential
        while (pc < self.program.instructions.len) {
            const instruction = &self.program.instructions[pc];

            switch (instruction.*) {
                .char => |c| {
                    if (input_pos >= input.len or input[input_pos] != c) {
                        return null;
                    }
                    input_pos += 1;
                    pc += 1;
                },
                .char_class => |*cc| {
                    if (input_pos >= input.len) {
                        return null;
                    }
                    const char = input[input_pos];
                    const codepoint: u21 = char;
                    var matched = false;

                    for (cc.ranges) |range| {
                        if (codepoint >= range.start and codepoint <= range.end) {
                            matched = true;
                            break;
                        }
                    }

                    if (matched == cc.negated) {
                        return null;
                    }

                    input_pos += 1;
                    pc += 1;
                },
                .any_char => {
                    if (input_pos >= input.len or input[input_pos] == '\n') {
                        return null;
                    }
                    input_pos += 1;
                    pc += 1;
                },
                .split => |split| {
                    // Just ignore splits for now
                    _ = split;
                    pc += 1;
                },
                .jump => |target| {
                    // Ignore jumps for simple linear execution
                    _ = target;
                    pc += 1;
                },
                .match_found => {
                    return input_pos;
                },
            }
        }

        return null;
    }

    fn executeFromPC(self: *const JITInterpreter, input: []const u8, input_pos: usize, pc: u32) RegexError!?usize {
        _ = self;
        _ = input;
        _ = input_pos;
        _ = pc;
        // Simplified implementation
        return null;
    }
};

test "jit compilation basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try root.Regex.compile(allocator, "hello");
    defer regex.deinit();

    var jit_compiler = JITCompiler.init(allocator);
    defer jit_compiler.deinit();

    var program = try jit_compiler.compile(regex.compiled.nfa.?);
    defer program.deinit();

    try std.testing.expect(program.instructions.len > 0);

    const interpreter = JITInterpreter.init(allocator, &program);
    const result = try interpreter.findMatch("hello world");
    try std.testing.expect(result != null);
}