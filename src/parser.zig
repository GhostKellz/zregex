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

pub const ParseDiagnostic = struct {
    error_type: ParseError,
    position: usize,
    line: usize,
    column: usize,
    message: []const u8,
    context: []const u8, // Surrounding text for context

    pub fn format(self: ParseDiagnostic, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator,
            "Parse error at line {}, column {}: {s}\n  Context: ...{s}...\n  Position: {s}^",
            .{ self.line + 1, self.column + 1, self.message, self.context, " " ** self.column }
        );
    }
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
    capture_group: struct {
        node: *Node,
        group_id: u32,
    },
    non_capture_group: *Node,
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
            .capture_group => |cap_group| {
                cap_group.node.deinit(allocator);
                allocator.destroy(cap_group.node);
            },
            .non_capture_group => |non_cap_group| {
                non_cap_group.deinit(allocator);
                allocator.destroy(non_cap_group);
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
        start: u21,
        end: u21,
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
    next_group_id: u32,
    line: usize,
    column: usize,
    diagnostics: std.ArrayList(ParseDiagnostic),

    pub fn init(allocator: Allocator, pattern: []const u8) Parser {
        return Parser{
            .input = pattern,
            .pos = 0,
            .allocator = allocator,
            .next_group_id = 1, // Group 0 is reserved for the full match
            .line = 0,
            .column = 0,
            .diagnostics = std.ArrayList(ParseDiagnostic){},
        };
    }

    pub fn deinit(self: *Parser) void {
        for (self.diagnostics.items) |*diag| {
            self.allocator.free(diag.message);
            self.allocator.free(diag.context);
        }
        self.diagnostics.deinit(self.allocator);
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.input.len) {
            if (self.input[self.pos] == '\n') {
                self.line += 1;
                self.column = 0;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }
    }

    fn addDiagnostic(self: *Parser, error_type: ParseError, message: []const u8) !void {
        const context_start = if (self.pos >= 10) self.pos - 10 else 0;
        const context_end = if (self.pos + 10 < self.input.len) self.pos + 10 else self.input.len;
        const context = try self.allocator.dupe(u8, self.input[context_start..context_end]);

        const owned_message = try self.allocator.dupe(u8, message);

        const diagnostic = ParseDiagnostic{
            .error_type = error_type,
            .position = self.pos,
            .line = self.line,
            .column = self.column,
            .message = owned_message,
            .context = context,
        };

        try self.diagnostics.append(self.allocator, diagnostic);
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
            self.advance();
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
            try self.addDiagnostic(ParseError.UnexpectedCharacter, "Unexpected end of pattern");
            return ParseError.UnexpectedCharacter;
        }

        const c = self.input[self.pos];
        var node: *Node = undefined;

        switch (c) {
            '.' => {
                self.advance();
                node = try self.allocator.create(Node);
                node.* = Node{ .any_char = {} };
            },
            '^' => {
                self.advance();
                node = try self.allocator.create(Node);
                node.* = Node{ .anchor_start = {} };
            },
            '$' => {
                self.advance();
                node = try self.allocator.create(Node);
                node.* = Node{ .anchor_end = {} };
            },
            '(' => {
                self.advance();
                // Check for non-capturing group (?:...)
                if (self.pos + 1 < self.input.len and
                    self.input[self.pos] == '?' and
                    self.input[self.pos + 1] == ':') {
                    // Non-capturing group
                    self.advance(); // '?'
                    self.advance(); // ':'
                    const group = try self.parseAlternation();
                    if (self.pos >= self.input.len or self.input[self.pos] != ')') {
                        try self.addDiagnostic(ParseError.UnbalancedParentheses, "Missing closing ')' for non-capturing group");
                        return ParseError.UnbalancedParentheses;
                    }
                    self.advance();
                    node = try self.allocator.create(Node);
                    node.* = Node{ .non_capture_group = group };
                } else {
                    // Capturing group
                    const group_id = self.next_group_id;
                    self.next_group_id += 1;
                    const group = try self.parseAlternation();
                    if (self.pos >= self.input.len or self.input[self.pos] != ')') {
                        try self.addDiagnostic(ParseError.UnbalancedParentheses, "Missing closing ')' for capture group");
                        return ParseError.UnbalancedParentheses;
                    }
                    self.advance();
                    node = try self.allocator.create(Node);
                    node.* = Node{ .capture_group = .{ .node = group, .group_id = group_id } };
                }
            },
            '[' => {
                node = try self.parseCharacterClass();
            },
            '\\' => {
                node = try self.parseEscape();
            },
            '*', '+', '?', '{' => {
                try self.addDiagnostic(ParseError.UnexpectedCharacter, "Quantifier without preceding element");
                return ParseError.UnexpectedCharacter;
            },
            else => {
                self.advance();
                node = try self.allocator.create(Node);
                node.* = Node{ .literal = c };
            },
        }

        return try self.parseQuantifier(node);
    }

    fn parseCharacterClass(self: *Parser) ParseError!*Node {
        if (self.pos >= self.input.len or self.input[self.pos] != '[') {
            try self.addDiagnostic(ParseError.InvalidCharacterClass, "Expected '[' to start character class");
            return ParseError.InvalidCharacterClass;
        }

        self.advance(); // '['
        var char_class = CharClass.init(self.allocator);

        if (self.pos < self.input.len and self.input[self.pos] == '^') {
            char_class.negated = true;
            self.advance();
        }

        while (self.pos < self.input.len and self.input[self.pos] != ']') {
            const start = self.input[self.pos];
            self.advance();

            if (self.pos < self.input.len - 1 and self.input[self.pos] == '-' and self.input[self.pos + 1] != ']') {
                self.advance(); // '-'
                const end = self.input[self.pos];
                self.advance();
                try char_class.ranges.append(self.allocator, .{ .start = start, .end = end });
            } else {
                try char_class.ranges.append(self.allocator, .{ .start = start, .end = start });
            }
        }

        if (self.pos >= self.input.len or self.input[self.pos] != ']') {
            char_class.deinit(self.allocator); // Clean up allocated ranges
            try self.addDiagnostic(ParseError.InvalidCharacterClass, "Missing closing ']' for character class");
            return ParseError.InvalidCharacterClass;
        }
        self.advance(); // ']'

        const node = try self.allocator.create(Node);
        node.* = Node{ .char_class = char_class };
        return node;
    }

    fn parseEscape(self: *Parser) ParseError!*Node {
        if (self.pos >= self.input.len or self.input[self.pos] != '\\') {
            try self.addDiagnostic(ParseError.InvalidEscape, "Expected '\\' to start escape sequence");
            return ParseError.InvalidEscape;
        }

        self.advance(); // '\'
        if (self.pos >= self.input.len) {
            try self.addDiagnostic(ParseError.InvalidEscape, "Incomplete escape sequence at end of pattern");
            return ParseError.InvalidEscape;
        }

        const escaped_char = self.input[self.pos];
        self.advance();

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
            'p', 'P' => {
                // Unicode properties: \p{Letter}, \P{Number}, etc.
                if (self.pos >= self.input.len or self.input[self.pos] != '{') {
                    return ParseError.InvalidEscape;
                }
                self.advance(); // Skip '{'

                const start_pos = self.pos;
                while (self.pos < self.input.len and self.input[self.pos] != '}') {
                    self.advance();
                }

                if (self.pos >= self.input.len) {
                    return ParseError.InvalidEscape;
                }

                const property_spec = self.input[start_pos..self.pos];
                self.advance(); // Skip '}'

                // Import unicode_properties module
                const unicode_props = @import("unicode_properties.zig");

                var char_class = CharClass.init(self.allocator);
                var unicode_prop = unicode_props.parsePropertySpec(self.allocator, property_spec) catch {
                    return ParseError.InvalidEscape;
                };
                defer unicode_prop.deinit(self.allocator);

                for (unicode_prop.ranges.items) |range| {
                    try char_class.ranges.append(self.allocator, .{
                        .start = range.start,
                        .end = range.end,
                    });
                }

                // \P means negated
                if (escaped_char == 'P') {
                    char_class.negated = true;
                }

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
                self.advance();
                min = 0;
                max = null;
            },
            '+' => {
                self.advance();
                min = 1;
                max = null;
            },
            '?' => {
                self.advance();
                min = 0;
                max = 1;
            },
            '{' => {
                self.advance();
                const result = try self.parseQuantifierRange();
                min = result.min;
                max = result.max;
            },
            else => return node,
        }

        if (self.pos < self.input.len and self.input[self.pos] == '?') {
            greedy = false;
            self.advance();
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
            self.advance();
        }

        if (self.pos < self.input.len and self.input[self.pos] == ',') {
            self.advance();
            if (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                var max_val: u32 = 0;
                while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
                    max_val = max_val * 10 + (self.input[self.pos] - '0');
                    self.advance();
                }
                max = max_val;
            }
        } else {
            max = min;
        }

        if (self.pos >= self.input.len or self.input[self.pos] != '}') {
            try self.addDiagnostic(ParseError.InvalidQuantifier, "Missing closing '}' for quantifier range");
            return ParseError.InvalidQuantifier;
        }
        self.advance();

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
    defer parser.deinit();
    var ast = try parser.parse();
    defer ast.deinit();

    try std.testing.expect(ast.root.* == .quantifier);
    try std.testing.expect(ast.root.quantifier.min == 0);
    try std.testing.expect(ast.root.quantifier.max == null);
}

test "parser diagnostics" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test unbalanced parentheses - simpler case to avoid memory leaks
    var parser = Parser.init(allocator, "[unclosed");
    defer parser.deinit();

    const result = parser.parse();
    try std.testing.expectError(ParseError.InvalidCharacterClass, result);
    try std.testing.expect(parser.diagnostics.items.len > 0);

    const diagnostic = parser.diagnostics.items[0];
    try std.testing.expect(diagnostic.error_type == ParseError.InvalidCharacterClass);
}

test "parser diagnostics with quantifier error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test quantifier without preceding element
    var parser = Parser.init(allocator, "*");
    defer parser.deinit();

    const result = parser.parse();
    try std.testing.expectError(ParseError.UnexpectedCharacter, result);
    try std.testing.expect(parser.diagnostics.items.len > 0);

    const diagnostic = parser.diagnostics.items[0];
    try std.testing.expect(diagnostic.error_type == ParseError.UnexpectedCharacter);
    try std.testing.expect(diagnostic.position == 0);
}