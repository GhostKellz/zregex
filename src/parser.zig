const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");

pub const ParseError = error{
    UnexpectedCharacter,
    UnbalancedParentheses,
    InvalidQuantifier,
    InvalidCharacterClass,
    InvalidEscape,
    OutOfMemory,
};

pub const AST = struct {
    root: *Node,
    allocator: Allocator,

    pub fn deinit(self: *AST) void {
        self.root.deinit(self.allocator);
        self.allocator.destroy(self.root);
    }
};

pub const Node = union(enum) {
    literal: u8,
    char_class: CharClass,
    any_char,
    anchor_start,
    anchor_end,
    group: *Node,
    alternation: struct {
        left: *Node,
        right: *Node,
    },
    concatenation: struct {
        left: *Node,
        right: *Node,
    },
    quantifier: struct {
        node: *Node,
        min: u32,
        max: ?u32,
        greedy: bool,
    },

    pub fn deinit(self: *Node, allocator: Allocator) void {
        switch (self.*) {
            .literal, .any_char, .anchor_start, .anchor_end => {},
            .char_class => |*cc| cc.deinit(allocator),
            .group => |group| {
                group.deinit(allocator);
                allocator.destroy(group);
            },
            .alternation => |alt| {
                alt.left.deinit(allocator);
                alt.right.deinit(allocator);
                allocator.destroy(alt.left);
                allocator.destroy(alt.right);
            },
            .concatenation => |concat| {
                concat.left.deinit(allocator);
                concat.right.deinit(allocator);
                allocator.destroy(concat.left);
                allocator.destroy(concat.right);
            },
            .quantifier => |quant| {
                quant.node.deinit(allocator);
                allocator.destroy(quant.node);
            },
        }
    }
};

pub const CharClass = struct {
    ranges: std.ArrayList(CharRange),
    negated: bool,

    pub const CharRange = struct {
        start: u8,
        end: u8,
    };

    pub fn init(allocator: Allocator) CharClass {
        _ = allocator;
        return CharClass{
            .ranges = std.ArrayList(CharRange){},
            .negated = false,
        };
    }

    pub fn deinit(self: *CharClass, allocator: Allocator) void {
        self.ranges.deinit(allocator);
    }
};

pub const Parser = struct {
    input: []const u8,
    pos: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, pattern: []const u8) Parser {
        return Parser{
            .input = pattern,
            .pos = 0,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser) ParseError!AST {
        const root = try self.parseAlternation();
        return AST{
            .root = root,
            .allocator = self.allocator,
        };
    }

    fn parseAlternation(self: *Parser) ParseError!*Node {
        var left = try self.parseConcatenation();

        while (self.pos < self.input.len and self.input[self.pos] == '|') {
            self.pos += 1;
            const right = try self.parseConcatenation();
            const alt_node = try self.allocator.create(Node);
            alt_node.* = Node{
                .alternation = .{
                    .left = left,
                    .right = right,
                },
            };
            left = alt_node;
        }

        return left;
    }

    fn parseConcatenation(self: *Parser) ParseError!*Node {
        var nodes = std.ArrayList(*Node){};
        defer nodes.deinit(self.allocator);

        while (self.pos < self.input.len and self.input[self.pos] != '|' and self.input[self.pos] != ')') {
            const atom = try self.parseAtom();
            try nodes.append(self.allocator, atom);
        }

        if (nodes.items.len == 0) {
            const empty_node = try self.allocator.create(Node);
            empty_node.* = Node{ .literal = 0 };
            return empty_node;
        }

        if (nodes.items.len == 1) {
            return nodes.items[0];
        }

        var result = nodes.items[0];
        for (nodes.items[1..]) |node| {
            const concat_node = try self.allocator.create(Node);
            concat_node.* = Node{
                .concatenation = .{
                    .left = result,
                    .right = node,
                },
            };
            result = concat_node;
        }

        return result;
    }

    fn parseAtom(self: *Parser) ParseError!*Node {
        if (self.pos >= self.input.len) {
            return ParseError.UnexpectedCharacter;
        }

        const c = self.input[self.pos];
        var node: *Node = undefined;

        switch (c) {
            '.' => {
                self.pos += 1;
                node = try self.allocator.create(Node);
                node.* = Node{ .any_char = {} };
            },
            '^' => {
                self.pos += 1;
                node = try self.allocator.create(Node);
                node.* = Node{ .anchor_start = {} };
            },
            '$' => {
                self.pos += 1;
                node = try self.allocator.create(Node);
                node.* = Node{ .anchor_end = {} };
            },
            '(' => {
                self.pos += 1;
                const group = try self.parseAlternation();
                if (self.pos >= self.input.len or self.input[self.pos] != ')') {
                    return ParseError.UnbalancedParentheses;
                }
                self.pos += 1;
                node = try self.allocator.create(Node);
                node.* = Node{ .group = group };
            },
            '[' => {
                node = try self.parseCharacterClass();
            },
            '\\' => {
                node = try self.parseEscape();
            },
            '*', '+', '?', '{' => {
                return ParseError.UnexpectedCharacter;
            },
            else => {
                self.pos += 1;
                node = try self.allocator.create(Node);
                node.* = Node{ .literal = c };
            },
        }

        return try self.parseQuantifier(node);
    }

    fn parseCharacterClass(self: *Parser) ParseError!*Node {
        if (self.pos >= self.input.len or self.input[self.pos] != '[') {
            return ParseError.InvalidCharacterClass;
        }

        self.pos += 1;
        var char_class = CharClass.init(self.allocator);

        if (self.pos < self.input.len and self.input[self.pos] == '^') {
            char_class.negated = true;
            self.pos += 1;
        }

        while (self.pos < self.input.len and self.input[self.pos] != ']') {
            const start = self.input[self.pos];
            self.pos += 1;

            if (self.pos < self.input.len - 1 and self.input[self.pos] == '-' and self.input[self.pos + 1] != ']') {
                self.pos += 1;
                const end = self.input[self.pos];
                self.pos += 1;
                try char_class.ranges.append(self.allocator, .{ .start = start, .end = end });
            } else {
                try char_class.ranges.append(self.allocator, .{ .start = start, .end = start });
            }
        }

        if (self.pos >= self.input.len or self.input[self.pos] != ']') {
            return ParseError.InvalidCharacterClass;
        }
        self.pos += 1;

        const node = try self.allocator.create(Node);
        node.* = Node{ .char_class = char_class };
        return node;
    }

    fn parseEscape(self: *Parser) ParseError!*Node {
        if (self.pos >= self.input.len or self.input[self.pos] != '\\') {
            return ParseError.InvalidEscape;
        }

        self.pos += 1;
        if (self.pos >= self.input.len) {
            return ParseError.InvalidEscape;
        }

        const escaped_char = self.input[self.pos];
        self.pos += 1;

        const node = try self.allocator.create(Node);
        switch (escaped_char) {
            'n' => node.* = Node{ .literal = '\n' },
            't' => node.* = Node{ .literal = '\t' },
            'r' => node.* = Node{ .literal = '\r' },
            'd', 'D', 'w', 'W', 's', 'S' => {
                // Predefined character classes
                var char_class = CharClass.init(self.allocator);
                const escape_seq = [_]u8{ '\\', escaped_char };
                var unicode_set = unicode.getPredefinedCharSet(self.allocator, &escape_seq) catch {
                    return ParseError.InvalidEscape;
                };
                defer unicode_set.deinit(self.allocator);

                for (unicode_set.ranges.items) |range| {
                    try char_class.ranges.append(self.allocator, .{
                        .start = @intCast(range.start),
                        .end = @intCast(range.end),
                    });
                }
                char_class.negated = unicode_set.negated;

                node.* = Node{ .char_class = char_class };
            },
            '\\', '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => {
                node.* = Node{ .literal = escaped_char };
            },
            else => node.* = Node{ .literal = escaped_char },
        }

        return node;
    }

    fn parseQuantifier(self: *Parser, node: *Node) ParseError!*Node {
        if (self.pos >= self.input.len) {
            return node;
        }

        const c = self.input[self.pos];
        var min: u32 = 0;
        var max: ?u32 = null;
        var greedy = true;

        switch (c) {
            '*' => {
                self.pos += 1;
                min = 0;
                max = null;
            },
            '+' => {
                self.pos += 1;
                min = 1;
                max = null;
            },
            '?' => {
                self.pos += 1;
                min = 0;
                max = 1;
            },
            '{' => {
                self.pos += 1;
                const result = try self.parseQuantifierRange();
                min = result.min;
                max = result.max;
            },
            else => return node,
        }

        if (self.pos < self.input.len and self.input[self.pos] == '?') {
            greedy = false;
            self.pos += 1;
        }

        const quant_node = try self.allocator.create(Node);
        quant_node.* = Node{
            .quantifier = .{
                .node = node,
                .min = min,
                .max = max,
                .greedy = greedy,
            },
        };

        return quant_node;
    }

    fn parseQuantifierRange(self: *Parser) ParseError!struct { min: u32, max: ?u32 } {
        var min: u32 = 0;
        var max: ?u32 = null;

        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
            min = min * 10 + (self.input[self.pos] - '0');
            self.pos += 1;
        }

        if (self.pos < self.input.len and self.input[self.pos] == ',') {
            self.pos += 1;
            if (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                var max_val: u32 = 0;
                while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                    max_val = max_val * 10 + (self.input[self.pos] - '0');
                    self.pos += 1;
                }
                max = max_val;
            }
        } else {
            max = min;
        }

        if (self.pos >= self.input.len or self.input[self.pos] != '}') {
            return ParseError.InvalidQuantifier;
        }
        self.pos += 1;

        return .{ .min = min, .max = max };
    }
};

test "basic literal parsing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser = Parser.init(allocator, "hello");
    var ast = try parser.parse();
    defer ast.deinit();

    try std.testing.expect(ast.root.* == .concatenation);
}

test "quantifier parsing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser = Parser.init(allocator, "a*");
    var ast = try parser.parse();
    defer ast.deinit();

    try std.testing.expect(ast.root.* == .quantifier);
    try std.testing.expect(ast.root.quantifier.min == 0);
    try std.testing.expect(ast.root.quantifier.max == null);
}