const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");

const NFA = root.NFA;
const Match = root.Match;
const RegexError = root.RegexError;

/// Enhanced instruction set with proper branching
pub const EnhancedInstruction = union(enum) {
    // Character matching
    char: u8,
    char_unicode: u21,
    char_class: CharClassInst,
    any_char,

    // Control flow
    split: SplitInst,       // Non-deterministic split
    jump: u32,              // Unconditional jump
    jump_if_match: JumpIfInst, // Conditional jump

    // Assertions
    assert_start,
    assert_end,
    assert_word_boundary,

    // Groups
    group_start: u32,
    group_end: u32,

    // Match
    match_found,
    fail,

    const CharClassInst = struct {
        ranges: []const CharRange,
        negated: bool,

        const CharRange = struct {
            start: u21,
            end: u21,
        };
    };

    const SplitInst = struct {
        target1: u32,  // First branch (higher priority)
        target2: u32,  // Second branch (lower priority)
        greedy: bool,  // Whether to prefer longer matches
    };

    const JumpIfInst = struct {
        target: u32,
        condition: Condition,

        const Condition = enum {
            at_start,
            at_end,
            word_boundary,
            not_word_boundary,
        };
    };
};

/// Enhanced bytecode program with optimization metadata
pub const EnhancedProgram = struct {
    instructions: []EnhancedInstruction,
    entry_point: u32 = 0,
    metadata: ProgramMetadata,
    allocator: Allocator,

    const ProgramMetadata = struct {
        has_backreferences: bool = false,
        min_match_length: usize = 0,
        max_match_length: ?usize = null,
        is_anchored_start: bool = false,
        is_anchored_end: bool = false,
        loop_depth: u32 = 0,
    };

    pub fn deinit(self: *EnhancedProgram) void {
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

/// Enhanced JIT compiler with optimization passes
pub const EnhancedJITCompiler = struct {
    allocator: Allocator,
    instructions: std.ArrayList(EnhancedInstruction),
    label_map: std.AutoHashMap(u32, u32), // NFA state -> instruction index
    metadata: EnhancedProgram.ProgramMetadata,

    pub fn init(allocator: Allocator) EnhancedJITCompiler {
        return EnhancedJITCompiler{
            .allocator = allocator,
            .instructions = std.ArrayList(EnhancedInstruction){},
            .label_map = std.AutoHashMap(u32, u32){},
            .metadata = .{},
        };
    }

    pub fn deinit(self: *EnhancedJITCompiler) void {
        self.instructions.deinit(self.allocator);
        self.label_map.deinit();
    }

    pub fn compile(self: *EnhancedJITCompiler, nfa: *const NFA) !EnhancedProgram {
        self.instructions.clearRetainingCapacity();
        self.label_map.clearRetainingCapacity();
        self.metadata = .{};

        // First pass: compile NFA to bytecode
        try self.compileNFAEnhanced(nfa);

        // Second pass: optimization
        try self.optimizeBytecode();

        // Third pass: fix jump targets
        try self.fixJumpTargets();

        const program = EnhancedProgram{
            .instructions = try self.instructions.toOwnedSlice(self.allocator),
            .metadata = self.metadata,
            .allocator = self.allocator,
        };

        return program;
    }

    fn compileNFAEnhanced(self: *EnhancedJITCompiler, nfa: *const NFA) !void {
        // Build state compilation order using topological sort
        var compile_queue = std.ArrayList(u32){};
        defer compile_queue.deinit(self.allocator);

        var visited = std.ArrayList(bool){};
        defer visited.deinit(self.allocator);
        try visited.resize(self.allocator, nfa.states.items.len);
        for (visited.items) |*v| v.* = false;

        // Start from the initial state
        try compile_queue.append(self.allocator, nfa.start_state);

        while (compile_queue.items.len > 0) {
            const state_id = compile_queue.orderedRemove(0);

            if (visited.items[state_id]) continue;
            visited.items[state_id] = true;

            // Record instruction position for this state
            try self.label_map.put(state_id, @intCast(self.instructions.items.len));

            const state = &nfa.states.items[state_id];

            if (state.is_accept) {
                try self.instructions.append(self.allocator, .match_found);
                continue;
            }

            // Handle different transition patterns
            if (state.transitions.items.len == 0) {
                try self.instructions.append(self.allocator, .fail);
            } else if (state.transitions.items.len == 1) {
                // Single transition - compile directly
                const transition = &state.transitions.items[0];
                try self.compileTransition(transition);

                // Add target to queue
                if (transition.target < nfa.states.items.len) {
                    try compile_queue.append(self.allocator, transition.target);
                }
            } else {
                // Multiple transitions - create split
                const split_inst = EnhancedInstruction{
                    .split = .{
                        .target1 = state.transitions.items[0].target,
                        .target2 = state.transitions.items[1].target,
                        .greedy = true, // Default to greedy matching
                    },
                };
                try self.instructions.append(self.allocator, split_inst);

                // Add all targets to queue
                for (state.transitions.items) |transition| {
                    if (transition.target < nfa.states.items.len) {
                        try compile_queue.append(self.allocator, transition.target);
                    }
                }
            }
        }
    }

    fn compileTransition(self: *EnhancedJITCompiler, transition: *const NFA.Transition) !void {
        switch (transition.condition) {
            .epsilon => {
                // Epsilon transition becomes a jump
                try self.instructions.append(self.allocator, .{ .jump = transition.target });
            },
            .char => |c| {
                if (c <= 127) {
                    try self.instructions.append(self.allocator, .{ .char = @intCast(c) });
                } else {
                    try self.instructions.append(self.allocator, .{ .char_unicode = c });
                }
            },
            .any_char => {
                try self.instructions.append(self.allocator, .any_char);
            },
            .char_class => |*char_class| {
                const ranges = try self.allocator.alloc(EnhancedInstruction.CharClassInst.CharRange, char_class.ranges.items.len);
                for (char_class.ranges.items, 0..) |range, i| {
                    ranges[i] = .{ .start = range.start, .end = range.end };
                }

                try self.instructions.append(self.allocator, .{
                    .char_class = .{
                        .ranges = ranges,
                        .negated = char_class.negated,
                    },
                });
            },
            .assert_start => {
                try self.instructions.append(self.allocator, .assert_start);
                self.metadata.is_anchored_start = true;
            },
            .assert_end => {
                try self.instructions.append(self.allocator, .assert_end);
                self.metadata.is_anchored_end = true;
            },
            .group_start => |group_id| {
                try self.instructions.append(self.allocator, .{ .group_start = group_id });
            },
            .group_end => |group_id| {
                try self.instructions.append(self.allocator, .{ .group_end = group_id });
            },
        }
    }

    fn optimizeBytecode(self: *EnhancedJITCompiler) !void {
        // Optimization pass 1: Remove redundant jumps
        var i: usize = 0;
        while (i < self.instructions.items.len) : (i += 1) {
            switch (self.instructions.items[i]) {
                .jump => |target| {
                    // Check if jumping to another jump
                    if (target < self.instructions.items.len) {
                        switch (self.instructions.items[target]) {
                            .jump => |next_target| {
                                // Collapse double jump
                                self.instructions.items[i] = .{ .jump = next_target };
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        // Optimization pass 2: Merge consecutive character matches into strings
        // (Could be implemented for better performance)
    }

    fn fixJumpTargets(self: *EnhancedJITCompiler) !void {
        // Update jump targets to use instruction indices instead of NFA state IDs
        for (self.instructions.items) |*inst| {
            switch (inst.*) {
                .jump => |*target| {
                    if (self.label_map.get(target.*)) |new_target| {
                        target.* = new_target;
                    }
                },
                .split => |*split| {
                    if (self.label_map.get(split.target1)) |new_target| {
                        split.target1 = new_target;
                    }
                    if (self.label_map.get(split.target2)) |new_target| {
                        split.target2 = new_target;
                    }
                },
                .jump_if_match => |*jump_if| {
                    if (self.label_map.get(jump_if.target)) |new_target| {
                        jump_if.target = new_target;
                    }
                },
                else => {},
            }
        }
    }
};

/// Enhanced JIT interpreter with backtracking support
pub const EnhancedJITInterpreter = struct {
    program: *const EnhancedProgram,
    allocator: Allocator,

    const Thread = struct {
        pc: u32,         // Program counter
        pos: usize,      // Position in input
        groups: ?[]?Match = null,
    };

    pub fn init(allocator: Allocator, program: *const EnhancedProgram) EnhancedJITInterpreter {
        return EnhancedJITInterpreter{
            .program = program,
            .allocator = allocator,
        };
    }

    pub fn findMatch(self: *const EnhancedJITInterpreter, input: []const u8) RegexError!?Match {
        // Quick checks based on metadata
        if (self.program.metadata.is_anchored_start) {
            return self.executeAt(input, 0);
        }

        // Try matching at each position
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

    fn executeAt(self: *const EnhancedJITInterpreter, input: []const u8, start_pos: usize) RegexError!?usize {
        var threads = std.ArrayList(Thread){};
        defer threads.deinit(self.allocator);

        // Start with initial thread
        try threads.append(self.allocator, Thread{
            .pc = self.program.entry_point,
            .pos = start_pos,
        });

        while (threads.items.len > 0) {
            var thread = threads.pop();

            while (thread.pc < self.program.instructions.len) {
                const inst = &self.program.instructions[thread.pc];

                switch (inst.*) {
                    .char => |c| {
                        if (thread.pos >= input.len or input[thread.pos] != c) {
                            break; // Thread fails
                        }
                        thread.pos += 1;
                        thread.pc += 1;
                    },
                    .char_unicode => |cp| {
                        // Handle Unicode character matching
                        const unicode = @import("unicode.zig");
                        var decode_pos = thread.pos;
                        const decoded = unicode.utf8DecodeNext(input, &decode_pos);
                        if (decoded == null or decoded.? != cp) {
                            break; // Thread fails
                        }
                        thread.pos = decode_pos;
                        thread.pc += 1;
                    },
                    .char_class => |*cc| {
                        if (thread.pos >= input.len) {
                            break; // Thread fails
                        }

                        const unicode = @import("unicode.zig");
                        var decode_pos = thread.pos;
                        const codepoint = unicode.utf8DecodeNext(input, &decode_pos);
                        if (codepoint == null) {
                            break; // Invalid UTF-8
                        }

                        var matched = false;
                        for (cc.ranges) |range| {
                            if (codepoint.? >= range.start and codepoint.? <= range.end) {
                                matched = true;
                                break;
                            }
                        }

                        if (matched == cc.negated) {
                            break; // Thread fails
                        }

                        thread.pos = decode_pos;
                        thread.pc += 1;
                    },
                    .any_char => {
                        if (thread.pos >= input.len or input[thread.pos] == '\n') {
                            break; // Thread fails
                        }

                        const unicode = @import("unicode.zig");
                        var decode_pos = thread.pos;
                        _ = unicode.utf8DecodeNext(input, &decode_pos);
                        thread.pos = decode_pos;
                        thread.pc += 1;
                    },
                    .split => |split| {
                        // Create new thread for second branch
                        try threads.append(self.allocator, Thread{
                            .pc = split.target2,
                            .pos = thread.pos,
                            .groups = thread.groups,
                        });

                        // Continue with first branch
                        thread.pc = split.target1;
                    },
                    .jump => |target| {
                        thread.pc = target;
                    },
                    .jump_if_match => |jump_if| {
                        const condition_met = switch (jump_if.condition) {
                            .at_start => thread.pos == 0,
                            .at_end => thread.pos >= input.len,
                            .word_boundary => false, // TODO: Implement
                            .not_word_boundary => true, // TODO: Implement
                        };

                        if (condition_met) {
                            thread.pc = jump_if.target;
                        } else {
                            thread.pc += 1;
                        }
                    },
                    .assert_start => {
                        if (thread.pos != 0) {
                            break; // Thread fails
                        }
                        thread.pc += 1;
                    },
                    .assert_end => {
                        if (thread.pos != input.len) {
                            break; // Thread fails
                        }
                        thread.pc += 1;
                    },
                    .assert_word_boundary => {
                        // TODO: Implement word boundary checking
                        thread.pc += 1;
                    },
                    .group_start, .group_end => {
                        // TODO: Implement group tracking
                        thread.pc += 1;
                    },
                    .match_found => {
                        return thread.pos;
                    },
                    .fail => {
                        break; // Thread fails
                    },
                }
            }
        }

        return null;
    }
};

test "enhanced JIT compilation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try root.Regex.compile(allocator, "a+b");
    defer regex.deinit();

    var compiler = EnhancedJITCompiler.init(allocator);
    defer compiler.deinit();

    if (regex.compiled.nfa) |nfa| {
        var program = try compiler.compile(nfa);
        defer program.deinit();

        try std.testing.expect(program.instructions.len > 0);

        const interpreter = EnhancedJITInterpreter.init(allocator, &program);
        const result = try interpreter.findMatch("aaab");
        try std.testing.expect(result != null);
    }
}

test "split instruction handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var regex = try root.Regex.compile(allocator, "a|b");
    defer regex.deinit();

    var compiler = EnhancedJITCompiler.init(allocator);
    defer compiler.deinit();

    if (regex.compiled.nfa) |nfa| {
        var program = try compiler.compile(nfa);
        defer program.deinit();

        // Check for split instruction
        var has_split = false;
        for (program.instructions) |inst| {
            switch (inst) {
                .split => {
                    has_split = true;
                    break;
                },
                else => {},
            }
        }
        try std.testing.expect(has_split);
    }
}