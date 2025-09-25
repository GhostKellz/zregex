const std = @import("std");
const parser = @import("src/parser.zig");
const nfa_builder = @import("src/nfa_builder.zig");
const matcher = @import("src/matcher.zig");

// Minimal NFA and related types without build_options
const NFA = struct {
    states: std.ArrayList(State),
    start_state: u32,
    accept_states: std.ArrayList(u32),

    const State = struct {
        id: u32,
        transitions: std.ArrayList(Transition),
        is_accept: bool = false,

        pub fn init(allocator: std.mem.Allocator, id: u32) State {
            _ = allocator;
            return State{
                .id = id,
                .transitions = std.ArrayList(Transition){},
            };
        }
    };

    const Transition = struct {
        target: u32,
        condition: TransitionCondition,
    };

    const TransitionCondition = union(enum) {
        epsilon,
        char: u8,
        char_class: CharClass,
        any_char,
    };

    pub fn init(allocator: std.mem.Allocator) NFA {
        _ = allocator;
        return NFA{
            .states = std.ArrayList(State){},
            .start_state = 0,
            .accept_states = std.ArrayList(u32){},
        };
    }

    pub fn deinit(self: *NFA, allocator: std.mem.Allocator) void {
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

const CharClass = struct {
    ranges: std.ArrayList(CharRange),
    negated: bool = false,

    const CharRange = struct {
        start: u21,
        end: u21,
    };

    pub fn init(allocator: std.mem.Allocator) CharClass {
        _ = allocator;
        return CharClass{
            .ranges = std.ArrayList(CharRange){},
        };
    }

    pub fn deinit(self: *CharClass, allocator: std.mem.Allocator) void {
        self.ranges.deinit(allocator);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use local types in NFABuilder
    const NFABuilder = struct {
        nfa: *NFA,
        allocator: std.mem.Allocator,
        next_state_id: u32,

        pub fn init(allocator_param: std.mem.Allocator) std.mem.Allocator.Error!@This() {
            const nfa = try allocator_param.create(NFA);
            nfa.* = NFA.init(allocator_param);

            return @This(){
                .nfa = nfa,
                .allocator = allocator_param,
                .next_state_id = 0,
            };
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    std.debug.print("Testing a* pattern construction...\\n", .{});

    var parser_inst = parser.Parser.init(allocator, "a*");
    var ast = try parser_inst.parse();
    defer ast.deinit();

    var builder = try NFABuilder.init(allocator);
    defer builder.deinit();

    // This won't work because we need the full nfa_builder functionality
    // Let's just test if the matcher fix works with existing NFA
}