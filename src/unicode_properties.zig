const std = @import("std");
const Allocator = std.mem.Allocator;

// Unicode property categories following the Unicode standard
pub const PropertyCategory = enum {
    // General categories
    letter,           // L
    lowercase_letter, // Ll
    uppercase_letter, // Lu
    titlecase_letter, // Lt
    modifier_letter,  // Lm
    other_letter,     // Lo

    mark,             // M
    nonspacing_mark,  // Mn
    spacing_mark,     // Mc
    enclosing_mark,   // Me

    number,           // N
    decimal_number,   // Nd
    letter_number,    // Nl
    other_number,     // No

    punctuation,      // P
    connector_punct,  // Pc
    dash_punct,       // Pd
    open_punct,       // Ps
    close_punct,      // Pe
    initial_punct,    // Pi
    final_punct,      // Pf
    other_punct,      // Po

    symbol,           // S
    math_symbol,      // Sm
    currency_symbol,  // Sc
    modifier_symbol,  // Sk
    other_symbol,     // So

    separator,        // Z
    space_separator,  // Zs
    line_separator,   // Zl
    para_separator,   // Zp

    other,            // C
    control,          // Cc
    format,           // Cf
    surrogate,        // Cs
    private_use,      // Co
    not_assigned,     // Cn

    // Script properties
    script_latin,
    script_greek,
    script_cyrillic,
    script_arabic,
    script_hebrew,
    script_hiragana,
    script_katakana,
    script_han,
    script_common,

    // Binary properties
    alphabetic,
    ascii,
    ascii_hex_digit,
    hex_digit,
    ideographic,
    lowercase,
    uppercase,
    white_space,
    xid_start,
    xid_continue,
};

pub const UnicodeProperty = struct {
    category: PropertyCategory,
    ranges: std.ArrayList(Range),

    const Range = struct {
        start: u21,
        end: u21,
    };

    pub fn init(allocator: Allocator, category: PropertyCategory) UnicodeProperty {
        _ = allocator;
        return UnicodeProperty{
            .category = category,
            .ranges = std.ArrayList(Range){},
        };
    }

    pub fn deinit(self: *UnicodeProperty, allocator: Allocator) void {
        self.ranges.deinit(allocator);
    }

    pub fn addRange(self: *UnicodeProperty, allocator: Allocator, start: u21, end: u21) !void {
        try self.ranges.append(allocator, .{ .start = start, .end = end });
    }

    pub fn matches(self: *const UnicodeProperty, codepoint: u21) bool {
        for (self.ranges.items) |range| {
            if (codepoint >= range.start and codepoint <= range.end) {
                return true;
            }
        }
        return false;
    }
};

// Parse Unicode property syntax: \p{Letter}, \p{L}, \p{Script=Latin}, etc.
pub fn parsePropertySpec(allocator: Allocator, spec: []const u8) !UnicodeProperty {
    // Remove surrounding braces if present
    var clean_spec = spec;
    if (spec.len > 2 and spec[0] == '{' and spec[spec.len - 1] == '}') {
        clean_spec = spec[1 .. spec.len - 1];
    }

    // Check for Script= syntax
    if (std.mem.startsWith(u8, clean_spec, "Script=")) {
        const script_name = clean_spec[7..];
        return getScriptProperty(allocator, script_name);
    }

    // Check for general category
    if (std.mem.eql(u8, clean_spec, "L") or std.mem.eql(u8, clean_spec, "Letter")) {
        return getLetterProperty(allocator);
    } else if (std.mem.eql(u8, clean_spec, "Ll") or std.mem.eql(u8, clean_spec, "Lowercase_Letter")) {
        return getLowercaseLetterProperty(allocator);
    } else if (std.mem.eql(u8, clean_spec, "Lu") or std.mem.eql(u8, clean_spec, "Uppercase_Letter")) {
        return getUppercaseLetterProperty(allocator);
    } else if (std.mem.eql(u8, clean_spec, "N") or std.mem.eql(u8, clean_spec, "Number")) {
        return getNumberProperty(allocator);
    } else if (std.mem.eql(u8, clean_spec, "Nd") or std.mem.eql(u8, clean_spec, "Decimal_Number")) {
        return getDecimalNumberProperty(allocator);
    } else if (std.mem.eql(u8, clean_spec, "P") or std.mem.eql(u8, clean_spec, "Punctuation")) {
        return getPunctuationProperty(allocator);
    } else if (std.mem.eql(u8, clean_spec, "S") or std.mem.eql(u8, clean_spec, "Symbol")) {
        return getSymbolProperty(allocator);
    } else if (std.mem.eql(u8, clean_spec, "Z") or std.mem.eql(u8, clean_spec, "Separator")) {
        return getSeparatorProperty(allocator);
    } else if (std.mem.eql(u8, clean_spec, "Zs") or std.mem.eql(u8, clean_spec, "Space_Separator")) {
        return getSpaceSeparatorProperty(allocator);
    } else if (std.mem.eql(u8, clean_spec, "ASCII")) {
        return getAsciiProperty(allocator);
    } else if (std.mem.eql(u8, clean_spec, "ASCII_Hex_Digit")) {
        return getAsciiHexDigitProperty(allocator);
    } else if (std.mem.eql(u8, clean_spec, "White_Space") or std.mem.eql(u8, clean_spec, "WSpace")) {
        return getWhiteSpaceProperty(allocator);
    }

    return error.UnknownProperty;
}

// Property definitions - simplified subsets for Beta
fn getLetterProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .letter);

    // Basic Latin
    try prop.addRange(allocator, 'A', 'Z');
    try prop.addRange(allocator, 'a', 'z');

    // Latin-1 Supplement
    try prop.addRange(allocator, 0x00C0, 0x00D6);
    try prop.addRange(allocator, 0x00D8, 0x00F6);
    try prop.addRange(allocator, 0x00F8, 0x00FF);

    // Latin Extended-A
    try prop.addRange(allocator, 0x0100, 0x017F);

    // Latin Extended-B
    try prop.addRange(allocator, 0x0180, 0x024F);

    // Greek
    try prop.addRange(allocator, 0x0370, 0x03FF);

    // Cyrillic
    try prop.addRange(allocator, 0x0400, 0x04FF);

    // Hebrew
    try prop.addRange(allocator, 0x0590, 0x05FF);

    // Arabic
    try prop.addRange(allocator, 0x0600, 0x06FF);

    // CJK Unified Ideographs (subset)
    try prop.addRange(allocator, 0x4E00, 0x9FFF);

    // Hiragana
    try prop.addRange(allocator, 0x3040, 0x309F);

    // Katakana
    try prop.addRange(allocator, 0x30A0, 0x30FF);

    return prop;
}

fn getLowercaseLetterProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .lowercase_letter);

    // Basic Latin
    try prop.addRange(allocator, 'a', 'z');

    // Latin-1 Supplement lowercase
    try prop.addRange(allocator, 0x00E0, 0x00F6);
    try prop.addRange(allocator, 0x00F8, 0x00FF);

    // Additional ranges would go here

    return prop;
}

fn getUppercaseLetterProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .uppercase_letter);

    // Basic Latin
    try prop.addRange(allocator, 'A', 'Z');

    // Latin-1 Supplement uppercase
    try prop.addRange(allocator, 0x00C0, 0x00D6);
    try prop.addRange(allocator, 0x00D8, 0x00DE);

    // Additional ranges would go here

    return prop;
}

fn getNumberProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .number);

    // ASCII digits
    try prop.addRange(allocator, '0', '9');

    // Arabic-Indic digits
    try prop.addRange(allocator, 0x0660, 0x0669);

    // Devanagari digits
    try prop.addRange(allocator, 0x0966, 0x096F);

    // Bengali digits
    try prop.addRange(allocator, 0x09E6, 0x09EF);

    // Additional numeric ranges would go here

    return prop;
}

fn getDecimalNumberProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .decimal_number);

    // ASCII digits
    try prop.addRange(allocator, '0', '9');

    // Other decimal number systems would go here

    return prop;
}

fn getPunctuationProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .punctuation);

    // Basic Latin punctuation
    try prop.addRange(allocator, 0x0021, 0x002F); // !"#$%&'()*+,-./
    try prop.addRange(allocator, 0x003A, 0x0040); // :;<=>?@
    try prop.addRange(allocator, 0x005B, 0x0060); // [\]^_`
    try prop.addRange(allocator, 0x007B, 0x007E); // {|}~

    // General Punctuation block (subset)
    try prop.addRange(allocator, 0x2000, 0x206F);

    return prop;
}

fn getSymbolProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .symbol);

    // Currency Symbols
    try prop.addRange(allocator, 0x20A0, 0x20CF);

    // Mathematical Operators
    try prop.addRange(allocator, 0x2200, 0x22FF);

    // Miscellaneous Symbols
    try prop.addRange(allocator, 0x2600, 0x26FF);

    return prop;
}

fn getSeparatorProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .separator);

    // Space separators
    try prop.addRange(allocator, 0x0020, 0x0020); // Space
    try prop.addRange(allocator, 0x00A0, 0x00A0); // No-break space
    try prop.addRange(allocator, 0x1680, 0x1680); // Ogham space
    try prop.addRange(allocator, 0x2000, 0x200A); // Various spaces

    // Line separator
    try prop.addRange(allocator, 0x2028, 0x2028);

    // Paragraph separator
    try prop.addRange(allocator, 0x2029, 0x2029);

    return prop;
}

fn getSpaceSeparatorProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .space_separator);

    try prop.addRange(allocator, 0x0020, 0x0020); // Space
    try prop.addRange(allocator, 0x00A0, 0x00A0); // No-break space
    try prop.addRange(allocator, 0x1680, 0x1680); // Ogham space
    try prop.addRange(allocator, 0x2000, 0x200A); // Various spaces
    try prop.addRange(allocator, 0x202F, 0x202F); // Narrow no-break space
    try prop.addRange(allocator, 0x205F, 0x205F); // Medium mathematical space
    try prop.addRange(allocator, 0x3000, 0x3000); // Ideographic space

    return prop;
}

fn getAsciiProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .ascii);
    try prop.addRange(allocator, 0x0000, 0x007F);
    return prop;
}

fn getAsciiHexDigitProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .ascii_hex_digit);
    try prop.addRange(allocator, '0', '9');
    try prop.addRange(allocator, 'A', 'F');
    try prop.addRange(allocator, 'a', 'f');
    return prop;
}

fn getWhiteSpaceProperty(allocator: Allocator) !UnicodeProperty {
    var prop = UnicodeProperty.init(allocator, .white_space);

    // ASCII whitespace
    try prop.addRange(allocator, 0x0009, 0x000D); // Tab through CR
    try prop.addRange(allocator, 0x0020, 0x0020); // Space

    // Other Unicode whitespace
    try prop.addRange(allocator, 0x0085, 0x0085); // Next Line
    try prop.addRange(allocator, 0x00A0, 0x00A0); // No-break space
    try prop.addRange(allocator, 0x1680, 0x1680); // Ogham space
    try prop.addRange(allocator, 0x2000, 0x200A); // Various spaces
    try prop.addRange(allocator, 0x2028, 0x2029); // Line/Para separators
    try prop.addRange(allocator, 0x202F, 0x202F); // Narrow no-break space
    try prop.addRange(allocator, 0x205F, 0x205F); // Medium mathematical space
    try prop.addRange(allocator, 0x3000, 0x3000); // Ideographic space

    return prop;
}

fn getScriptProperty(allocator: Allocator, script_name: []const u8) !UnicodeProperty {
    if (std.mem.eql(u8, script_name, "Latin")) {
        var prop = UnicodeProperty.init(allocator, .script_latin);

        // Basic Latin
        try prop.addRange(allocator, 'A', 'Z');
        try prop.addRange(allocator, 'a', 'z');

        // Latin-1 Supplement
        try prop.addRange(allocator, 0x00C0, 0x00FF);

        // Latin Extended
        try prop.addRange(allocator, 0x0100, 0x024F);
        try prop.addRange(allocator, 0x1E00, 0x1EFF);
        try prop.addRange(allocator, 0x2C60, 0x2C7F);
        try prop.addRange(allocator, 0xA720, 0xA7FF);

        return prop;
    } else if (std.mem.eql(u8, script_name, "Greek")) {
        var prop = UnicodeProperty.init(allocator, .script_greek);
        try prop.addRange(allocator, 0x0370, 0x03FF);
        try prop.addRange(allocator, 0x1F00, 0x1FFF);
        return prop;
    } else if (std.mem.eql(u8, script_name, "Cyrillic")) {
        var prop = UnicodeProperty.init(allocator, .script_cyrillic);
        try prop.addRange(allocator, 0x0400, 0x04FF);
        try prop.addRange(allocator, 0x0500, 0x052F);
        try prop.addRange(allocator, 0x2DE0, 0x2DFF);
        try prop.addRange(allocator, 0xA640, 0xA69F);
        return prop;
    } else if (std.mem.eql(u8, script_name, "Hebrew")) {
        var prop = UnicodeProperty.init(allocator, .script_hebrew);
        try prop.addRange(allocator, 0x0590, 0x05FF);
        return prop;
    } else if (std.mem.eql(u8, script_name, "Arabic")) {
        var prop = UnicodeProperty.init(allocator, .script_arabic);
        try prop.addRange(allocator, 0x0600, 0x06FF);
        try prop.addRange(allocator, 0x0750, 0x077F);
        return prop;
    } else if (std.mem.eql(u8, script_name, "Hiragana")) {
        var prop = UnicodeProperty.init(allocator, .script_hiragana);
        try prop.addRange(allocator, 0x3040, 0x309F);
        return prop;
    } else if (std.mem.eql(u8, script_name, "Katakana")) {
        var prop = UnicodeProperty.init(allocator, .script_katakana);
        try prop.addRange(allocator, 0x30A0, 0x30FF);
        try prop.addRange(allocator, 0x31F0, 0x31FF);
        return prop;
    } else if (std.mem.eql(u8, script_name, "Han")) {
        var prop = UnicodeProperty.init(allocator, .script_han);
        try prop.addRange(allocator, 0x4E00, 0x9FFF); // CJK Unified Ideographs
        try prop.addRange(allocator, 0x3400, 0x4DBF); // CJK Extension A
        return prop;
    }

    return error.UnknownScript;
}

// Case folding support for case-insensitive matching
pub fn caseFold(codepoint: u21) u21 {
    // Simple case folding for ASCII
    if (codepoint >= 'A' and codepoint <= 'Z') {
        return codepoint + 32;
    }

    // Latin-1 Supplement uppercase to lowercase
    if (codepoint >= 0x00C0 and codepoint <= 0x00D6) {
        return codepoint + 32;
    }
    if (codepoint >= 0x00D8 and codepoint <= 0x00DE) {
        return codepoint + 32;
    }

    // TODO: Add more comprehensive case folding tables

    return codepoint;
}

test "unicode property matching" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test Letter property
    var letter_prop = try parsePropertySpec(allocator, "L");
    defer letter_prop.deinit(allocator);

    try std.testing.expect(letter_prop.matches('A'));
    try std.testing.expect(letter_prop.matches('z'));
    try std.testing.expect(!letter_prop.matches('0'));
    try std.testing.expect(!letter_prop.matches(' '));

    // Test with extended Latin
    try std.testing.expect(letter_prop.matches(0x00E9)); // é
    try std.testing.expect(letter_prop.matches(0x00C0)); // À

    // Test Number property
    var number_prop = try parsePropertySpec(allocator, "N");
    defer number_prop.deinit(allocator);

    try std.testing.expect(number_prop.matches('5'));
    try std.testing.expect(!number_prop.matches('A'));

    // Test Script property
    var latin_script = try parsePropertySpec(allocator, "Script=Latin");
    defer latin_script.deinit(allocator);

    try std.testing.expect(latin_script.matches('A'));
    try std.testing.expect(latin_script.matches(0x00E9)); // é
    try std.testing.expect(!latin_script.matches(0x0391)); // Greek Alpha
}

test "case folding" {
    try std.testing.expectEqual(@as(u21, 'a'), caseFold('A'));
    try std.testing.expectEqual(@as(u21, 'z'), caseFold('Z'));
    try std.testing.expectEqual(@as(u21, 'a'), caseFold('a'));
    try std.testing.expectEqual(@as(u21, '5'), caseFold('5'));

    // Latin-1 supplement
    try std.testing.expectEqual(@as(u21, 0x00E0), caseFold(0x00C0)); // À -> à
}