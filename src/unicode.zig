const std = @import("std");
const Allocator = std.mem.Allocator;

pub const UnicodeCategory = enum {
    letter,
    number,
    punctuation,
    symbol,
    separator,
    mark,
    other,
};

pub const CharSet = struct {
    ranges: std.ArrayList(Range),
    negated: bool = false,

    const Range = struct {
        start: u21,
        end: u21,
    };

    pub fn init(allocator: Allocator) CharSet {
        _ = allocator;
        return CharSet{
            .ranges = std.ArrayList(Range){},
        };
    }

    pub fn deinit(self: *CharSet, allocator: Allocator) void {
        self.ranges.deinit(allocator);
    }

    pub fn addRange(self: *CharSet, allocator: Allocator, start: u21, end: u21) !void {
        try self.ranges.append(allocator, .{ .start = start, .end = end });
    }

    pub fn addChar(self: *CharSet, allocator: Allocator, char: u21) !void {
        try self.addRange(allocator, char, char);
    }

    pub fn contains(self: *const CharSet, codepoint: u21) bool {
        for (self.ranges.items) |range| {
            if (codepoint >= range.start and codepoint <= range.end) {
                return !self.negated;
            }
        }
        return self.negated;
    }

    pub fn negate(self: *CharSet) void {
        self.negated = !self.negated;
    }
};

pub fn getPredefinedCharSet(allocator: Allocator, name: []const u8) error{OutOfMemory, UnknownCharacterClass}!CharSet {
    var char_set = CharSet.init(allocator);

    if (std.mem.eql(u8, name, "\\d")) {
        // Digits 0-9
        try char_set.addRange(allocator, '0', '9');
    } else if (std.mem.eql(u8, name, "\\D")) {
        // Non-digits
        try char_set.addRange(allocator, '0', '9');
        char_set.negate();
    } else if (std.mem.eql(u8, name, "\\w")) {
        // Word characters: letters, digits, underscore
        try char_set.addRange(allocator, 'a', 'z');
        try char_set.addRange(allocator, 'A', 'Z');
        try char_set.addRange(allocator, '0', '9');
        try char_set.addChar(allocator, '_');
    } else if (std.mem.eql(u8, name, "\\W")) {
        // Non-word characters
        try char_set.addRange(allocator, 'a', 'z');
        try char_set.addRange(allocator, 'A', 'Z');
        try char_set.addRange(allocator, '0', '9');
        try char_set.addChar(allocator, '_');
        char_set.negate();
    } else if (std.mem.eql(u8, name, "\\s")) {
        // Whitespace characters
        try char_set.addChar(allocator, ' ');
        try char_set.addChar(allocator, '\t');
        try char_set.addChar(allocator, '\r');
        try char_set.addChar(allocator, '\n');
        try char_set.addChar(allocator, '\x0B'); // vertical tab
        try char_set.addChar(allocator, '\x0C'); // form feed
    } else if (std.mem.eql(u8, name, "\\S")) {
        // Non-whitespace characters
        try char_set.addChar(allocator, ' ');
        try char_set.addChar(allocator, '\t');
        try char_set.addChar(allocator, '\r');
        try char_set.addChar(allocator, '\n');
        try char_set.addChar(allocator, '\x0B');
        try char_set.addChar(allocator, '\x0C');
        char_set.negate();
    } else {
        return error.UnknownCharacterClass;
    }

    return char_set;
}

pub fn utf8DecodeNext(input: []const u8, pos: *usize) ?u21 {
    if (pos.* >= input.len) return null;

    const first_byte = input[pos.*];
    var codepoint: u21 = 0;
    var len: usize = 0;

    if (first_byte & 0x80 == 0) {
        // ASCII (0xxxxxxx)
        codepoint = first_byte;
        len = 1;
    } else if (first_byte & 0xE0 == 0xC0) {
        // 2-byte sequence (110xxxxx 10xxxxxx)
        if (pos.* + 1 >= input.len) return null;
        codepoint = (@as(u21, first_byte & 0x1F) << 6) |
            (@as(u21, input[pos.* + 1] & 0x3F));
        len = 2;
    } else if (first_byte & 0xF0 == 0xE0) {
        // 3-byte sequence (1110xxxx 10xxxxxx 10xxxxxx)
        if (pos.* + 2 >= input.len) return null;
        codepoint = (@as(u21, first_byte & 0x0F) << 12) |
            (@as(u21, input[pos.* + 1] & 0x3F) << 6) |
            (@as(u21, input[pos.* + 2] & 0x3F));
        len = 3;
    } else if (first_byte & 0xF8 == 0xF0) {
        // 4-byte sequence (11110xxx 10xxxxxx 10xxxxxx 10xxxxxx)
        if (pos.* + 3 >= input.len) return null;
        codepoint = (@as(u21, first_byte & 0x07) << 18) |
            (@as(u21, input[pos.* + 1] & 0x3F) << 12) |
            (@as(u21, input[pos.* + 2] & 0x3F) << 6) |
            (@as(u21, input[pos.* + 3] & 0x3F));
        len = 4;
    } else {
        // Invalid UTF-8
        return null;
    }

    pos.* += len;
    return codepoint;
}

pub fn isLetter(codepoint: u21) bool {
    // Basic Latin letters
    if ((codepoint >= 'A' and codepoint <= 'Z') or
        (codepoint >= 'a' and codepoint <= 'z'))
    {
        return true;
    }

    // Extended Latin ranges (simplified)
    if (codepoint >= 0x00C0 and codepoint <= 0x024F) return true; // Latin Extended A & B
    if (codepoint >= 0x1E00 and codepoint <= 0x1EFF) return true; // Latin Extended Additional

    return false;
}

pub fn isDigit(codepoint: u21) bool {
    return codepoint >= '0' and codepoint <= '9';
}

pub fn isWhitespace(codepoint: u21) bool {
    return codepoint == ' ' or codepoint == '\t' or codepoint == '\r' or
        codepoint == '\n' or codepoint == 0x0B or codepoint == 0x0C;
}

test "utf8 decoding" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var pos: usize = 0;

    // Test ASCII
    const ascii = "Hello";
    pos = 0;
    try std.testing.expect(utf8DecodeNext(ascii, &pos) == 'H');
    try std.testing.expect(pos == 1);

    // Test multi-byte UTF-8
    const utf8_str = "é"; // U+00E9 (2 bytes in UTF-8: 0xC3 0xA9)
    pos = 0;
    const codepoint = utf8DecodeNext(utf8_str, &pos);
    try std.testing.expect(codepoint == 0x00E9);
    try std.testing.expect(pos == 2);
}

test "character sets" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var digit_set = try getPredefinedCharSet(allocator, "\\d");
    defer digit_set.deinit(allocator);

    try std.testing.expect(digit_set.contains('5'));
    try std.testing.expect(!digit_set.contains('a'));

    var word_set = try getPredefinedCharSet(allocator, "\\w");
    defer word_set.deinit(allocator);

    try std.testing.expect(word_set.contains('A'));
    try std.testing.expect(word_set.contains('_'));
    try std.testing.expect(!word_set.contains(' '));
}