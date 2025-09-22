const std = @import("std");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const root = @import("root.zig");

const NFA = root.NFA;
const Transition = NFA.Transition;
const State = NFA.State;
const TransitionCondition = NFA.TransitionCondition;

pub const NFABuilder = struct {
    nfa: *NFA,
    allocator: Allocator,
    next_state_id: u32,

    pub fn init(allocator: Allocator) std.mem.Allocator.Error!NFABuilder {
        const nfa = try allocator.create(NFA);
        nfa.* = NFA.init(allocator);

        return NFABuilder{
            .nfa = nfa,
            .allocator = allocator,
            .next_state_id = 0,
        };
    }

    pub fn deinit(self: *NFABuilder) void {
        _ = self;
    }

    pub fn build(self: *NFABuilder, ast: *parser.AST) std.mem.Allocator.Error!*NFA {
        const fragment = try self.compileNode(ast.root);

        self.nfa.start_state = fragment.start;
        try self.nfa.accept_states.append(self.allocator, fragment.end);

        const accept_state = &self.nfa.states.items[fragment.end];
        accept_state.is_accept = true;

        return self.nfa;
    }

    const Fragment = struct {
        start: u32,
        end: u32,
    };

    fn createState(self: *NFABuilder) std.mem.Allocator.Error!u32 {
        const state_id = self.next_state_id;
        self.next_state_id += 1;

        const state = State.init(self.allocator, state_id);
        try self.nfa.states.append(self.allocator, state);

        return state_id;
    }

    fn addTransition(self: *NFABuilder, from: u32, to: u32, condition: TransitionCondition) std.mem.Allocator.Error!void {
        const transition = Transition{
            .target = to,
            .condition = condition,
        };

        try self.nfa.states.items[from].transitions.append(self.allocator, transition);
    }

    fn compileNode(self: *NFABuilder, node: *parser.Node) std.mem.Allocator.Error!Fragment {
        switch (node.*) {
            .literal => |char| {
                return try self.compileLiteral(char);
            },
            .any_char => {
                return try self.compileAnyChar();
            },
            .char_class => |*char_class| {
                return try self.compileCharClass(char_class);
            },
            .concatenation => |concat| {
                return try self.compileConcatenation(concat.left, concat.right);
            },
            .alternation => |alt| {
                return try self.compileAlternation(alt.left, alt.right);
            },
            .quantifier => |quant| {
                return try self.compileQuantifier(quant.node, quant.min, quant.max, quant.greedy);
            },
            .group => |group| {
                return try self.compileNode(group);
            },
            .anchor_start, .anchor_end => {
                return try self.compileEpsilon();
            },
        }
    }

    fn compileLiteral(self: *NFABuilder, char: u8) std.mem.Allocator.Error!Fragment {
        const start_state = try self.createState();
        const end_state = try self.createState();

        try self.addTransition(start_state, end_state, .{ .char = char });

        return Fragment{
            .start = start_state,
            .end = end_state,
        };
    }

    fn compileAnyChar(self: *NFABuilder) std.mem.Allocator.Error!Fragment {
        const start_state = try self.createState();
        const end_state = try self.createState();

        try self.addTransition(start_state, end_state, .any_char);

        return Fragment{
            .start = start_state,
            .end = end_state,
        };
    }

    fn compileCharClass(self: *NFABuilder, char_class: *parser.CharClass) std.mem.Allocator.Error!Fragment {
        const start_state = try self.createState();
        const end_state = try self.createState();

        var root_char_class = root.CharClass.init(self.allocator);
        errdefer root_char_class.deinit(self.allocator);

        for (char_class.ranges.items) |range| {
            try root_char_class.ranges.append(self.allocator, .{
                .start = range.start,
                .end = range.end,
            });
        }
        root_char_class.negated = char_class.negated;

        try self.addTransition(start_state, end_state, .{ .char_class = root_char_class });

        return Fragment{
            .start = start_state,
            .end = end_state,
        };
    }

    fn compileEpsilon(self: *NFABuilder) std.mem.Allocator.Error!Fragment {
        const start_state = try self.createState();
        const end_state = try self.createState();

        try self.addTransition(start_state, end_state, .epsilon);

        return Fragment{
            .start = start_state,
            .end = end_state,
        };
    }

    fn compileConcatenation(self: *NFABuilder, left: *parser.Node, right: *parser.Node) std.mem.Allocator.Error!Fragment {
        const left_frag = try self.compileNode(left);
        const right_frag = try self.compileNode(right);

        try self.addTransition(left_frag.end, right_frag.start, .epsilon);

        return Fragment{
            .start = left_frag.start,
            .end = right_frag.end,
        };
    }

    fn compileAlternation(self: *NFABuilder, left: *parser.Node, right: *parser.Node) std.mem.Allocator.Error!Fragment {
        const left_frag = try self.compileNode(left);
        const right_frag = try self.compileNode(right);

        const start_state = try self.createState();
        const end_state = try self.createState();

        try self.addTransition(start_state, left_frag.start, .epsilon);
        try self.addTransition(start_state, right_frag.start, .epsilon);
        try self.addTransition(left_frag.end, end_state, .epsilon);
        try self.addTransition(right_frag.end, end_state, .epsilon);

        return Fragment{
            .start = start_state,
            .end = end_state,
        };
    }

    fn compileQuantifier(self: *NFABuilder, node: *parser.Node, min: u32, max: ?u32, greedy: bool) std.mem.Allocator.Error!Fragment {
        _ = greedy;

        if (min == 0 and max == null) {
            return try self.compileKleeneStar(node);
        } else if (min == 1 and max == null) {
            return try self.compilePlus(node);
        } else if (min == 0 and max != null and max.? == 1) {
            return try self.compileOptional(node);
        } else {
            return try self.compileRange(node, min, max);
        }
    }

    fn compileKleeneStar(self: *NFABuilder, node: *parser.Node) std.mem.Allocator.Error!Fragment {
        const inner_frag = try self.compileNode(node);
        const start_state = try self.createState();
        const end_state = try self.createState();

        try self.addTransition(start_state, inner_frag.start, .epsilon);
        try self.addTransition(start_state, end_state, .epsilon);
        try self.addTransition(inner_frag.end, inner_frag.start, .epsilon);
        try self.addTransition(inner_frag.end, end_state, .epsilon);

        return Fragment{
            .start = start_state,
            .end = end_state,
        };
    }

    fn compilePlus(self: *NFABuilder, node: *parser.Node) std.mem.Allocator.Error!Fragment {
        const inner_frag = try self.compileNode(node);
        const end_state = try self.createState();

        try self.addTransition(inner_frag.end, inner_frag.start, .epsilon);
        try self.addTransition(inner_frag.end, end_state, .epsilon);

        return Fragment{
            .start = inner_frag.start,
            .end = end_state,
        };
    }

    fn compileOptional(self: *NFABuilder, node: *parser.Node) std.mem.Allocator.Error!Fragment {
        const inner_frag = try self.compileNode(node);
        const start_state = try self.createState();
        const end_state = try self.createState();

        try self.addTransition(start_state, inner_frag.start, .epsilon);
        try self.addTransition(start_state, end_state, .epsilon);
        try self.addTransition(inner_frag.end, end_state, .epsilon);

        return Fragment{
            .start = start_state,
            .end = end_state,
        };
    }

    fn compileRange(self: *NFABuilder, node: *parser.Node, min: u32, max: ?u32) std.mem.Allocator.Error!Fragment {
        if (min == 0) {
            const optional_frag = try self.compileOptional(node);
            return optional_frag;
        }

        var current_frag = try self.compileNode(node);

        var i: u32 = 1;
        while (i < min) : (i += 1) {
            const next_frag = try self.compileNode(node);
            try self.addTransition(current_frag.end, next_frag.start, .epsilon);
            current_frag.end = next_frag.end;
        }

        if (max) |max_count| {
            i = min;
            while (i < max_count) : (i += 1) {
                const optional_frag = try self.compileOptional(node);
                try self.addTransition(current_frag.end, optional_frag.start, .epsilon);
                current_frag.end = optional_frag.end;
            }
        }

        return current_frag;
    }
};

test "nfa literal compilation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser_inst = parser.Parser.init(allocator, "a");
    var ast = try parser_inst.parse();
    defer ast.deinit();

    var builder = try NFABuilder.init(allocator);
    defer builder.deinit();

    const nfa = try builder.build(&ast);
    defer nfa.deinit(allocator);
    try std.testing.expect(nfa.states.items.len > 0);
}

test "nfa kleene star compilation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser_inst = parser.Parser.init(allocator, "a*");
    var ast = try parser_inst.parse();
    defer ast.deinit();

    var builder = try NFABuilder.init(allocator);
    defer builder.deinit();

    const nfa = try builder.build(&ast);
    defer nfa.deinit(allocator);
    try std.testing.expect(nfa.states.items.len > 0);
    try std.testing.expect(nfa.accept_states.items.len == 1);
}