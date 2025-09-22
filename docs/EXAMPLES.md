# zregex Examples

Comprehensive examples showing how to use zregex for common regex tasks.

## 📧 Email Validation

### Basic Email Check

```zig
const std = @import("std");
const zregex = @import("zregex");

pub fn validateEmail(allocator: std.mem.Allocator, email: []const u8) !bool {
    var regex = try zregex.Regex.compile(allocator,
        "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}");
    defer regex.deinit();

    return try regex.isMatch(email);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const emails = [_][]const u8{
        "user@example.com",
        "test.email+tag@domain.co.uk",
        "invalid.email",
        "another@valid.org",
    };

    for (emails) |email| {
        const valid = try validateEmail(allocator, email);
        std.debug.print("{s}: {s}\n", .{ email, if (valid) "✅ Valid" else "❌ Invalid" });
    }
}
```

### Email Extraction

```zig
pub fn extractEmails(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var regex = try zregex.Regex.compile(allocator,
        "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, text);
    defer allocator.free(matches);

    var emails = try allocator.alloc([]const u8, matches.len);
    for (matches, 0..) |match, i| {
        emails[i] = try allocator.dupe(u8, match.slice(text));
    }

    return emails;
}
```

## 📞 Phone Number Processing

### US Phone Number Validation

```zig
pub fn validateUSPhone(allocator: std.mem.Allocator, phone: []const u8) !bool {
    // Matches: (555) 123-4567, 555-123-4567, 5551234567
    var regex = try zregex.Regex.compile(allocator,
        "^(?:\\(\\d{3}\\)\\s*|\\d{3}[-.]?)\\d{3}[-.]?\\d{4}$");
    defer regex.deinit();

    return try regex.isMatch(phone);
}

pub fn formatPhone(allocator: std.mem.Allocator, phone: []const u8) !?[]const u8 {
    // Extract digits only
    var digit_regex = try zregex.Regex.compile(allocator, "\\d");
    defer digit_regex.deinit();

    const digit_matches = try digit_regex.findAll(allocator, phone);
    defer allocator.free(digit_matches);

    if (digit_matches.len != 10) return null; // US phones have 10 digits

    // Build formatted string
    var formatted = try allocator.alloc(u8, 14); // "(555) 123-4567"
    var digit_idx: usize = 0;

    formatted[0] = '(';
    for (1..4) |i| {
        formatted[i] = digit_matches[digit_idx].slice(phone)[0];
        digit_idx += 1;
    }
    formatted[4] = ')';
    formatted[5] = ' ';

    for (6..9) |i| {
        formatted[i] = digit_matches[digit_idx].slice(phone)[0];
        digit_idx += 1;
    }
    formatted[9] = '-';

    for (10..14) |i| {
        formatted[i] = digit_matches[digit_idx].slice(phone)[0];
        digit_idx += 1;
    }

    return formatted;
}
```

## 📝 Log File Processing

### Apache Log Parser

```zig
const LogEntry = struct {
    ip: []const u8,
    timestamp: []const u8,
    method: []const u8,
    url: []const u8,
    status: u32,
    size: u32,
};

pub fn parseApacheLog(allocator: std.mem.Allocator, log_line: []const u8) !?LogEntry {
    // Apache Common Log Format
    var regex = try zregex.Regex.compile(allocator,
        "^(\\S+) \\S+ \\S+ \\[([^\\]]+)\\] \"(\\w+) ([^\"]+) [^\"]+\" (\\d+) (\\d+)");
    defer regex.deinit();

    if (try regex.find(log_line)) |match| {
        // Note: This is a simplified example
        // In practice, you'd extract capture groups
        return LogEntry{
            .ip = "127.0.0.1", // Would extract from groups
            .timestamp = "01/Jan/2024:12:00:00 +0000",
            .method = "GET",
            .url = "/index.html",
            .status = 200,
            .size = 1024,
        };
    }

    return null;
}

pub fn processLogFile(allocator: std.mem.Allocator, file_path: []const u8) !void {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var error_regex = try zregex.Regex.compile(allocator, " [45]\\d\\d ");
    defer error_regex.deinit();

    var line_buffer: [1024]u8 = undefined;
    var error_count: u32 = 0;
    var total_lines: u32 = 0;

    while (try file.reader().readUntilDelimiterOrEof(&line_buffer, '\n')) |line| {
        total_lines += 1;

        if (try error_regex.isMatch(line)) {
            error_count += 1;
            std.debug.print("Error: {s}\n", .{line});
        }
    }

    std.debug.print("Processed {} lines, found {} errors\n", .{ total_lines, error_count });
}
```

## 🔍 Text Search and Replace

### Find and Replace

```zig
pub fn replacePattern(allocator: std.mem.Allocator, text: []const u8,
                     pattern: []const u8, replacement: []const u8) ![]u8 {
    var regex = try zregex.Regex.compile(allocator, pattern);
    defer regex.deinit();

    const matches = try regex.findAll(allocator, text);
    defer allocator.free(matches);

    if (matches.len == 0) {
        return try allocator.dupe(u8, text);
    }

    // Calculate result size
    var result_size = text.len;
    for (matches) |match| {
        result_size = result_size - (match.end - match.start) + replacement.len;
    }

    var result = try allocator.alloc(u8, result_size);
    var result_pos: usize = 0;
    var text_pos: usize = 0;

    for (matches) |match| {
        // Copy text before match
        const before_len = match.start - text_pos;
        @memcpy(result[result_pos..result_pos + before_len], text[text_pos..match.start]);
        result_pos += before_len;

        // Copy replacement
        @memcpy(result[result_pos..result_pos + replacement.len], replacement);
        result_pos += replacement.len;

        text_pos = match.end;
    }

    // Copy remaining text
    if (text_pos < text.len) {
        @memcpy(result[result_pos..], text[text_pos..]);
    }

    return result;
}
```

### Word Counter

```zig
pub fn countWords(allocator: std.mem.Allocator, text: []const u8) !u32 {
    var word_regex = try zregex.Regex.compile(allocator, "\\w+");
    defer word_regex.deinit();

    const matches = try word_regex.findAll(allocator, text);
    defer allocator.free(matches);

    return @intCast(matches.len);
}

pub fn findLongWords(allocator: std.mem.Allocator, text: []const u8, min_length: u32) ![][]const u8 {
    // Create pattern for words of minimum length
    var pattern_buf: [64]u8 = undefined;
    const pattern = try std.fmt.bufPrint(&pattern_buf, "\\w{{{},}}", .{min_length});

    var regex = try zregex.Regex.compile(allocator, pattern);
    defer regex.deinit();

    const matches = try regex.findAll(allocator, text);
    defer allocator.free(matches);

    var words = try allocator.alloc([]const u8, matches.len);
    for (matches, 0..) |match, i| {
        words[i] = try allocator.dupe(u8, match.slice(text));
    }

    return words;
}
```

## 💰 Financial Data Processing

### Currency Amount Extraction

```zig
pub fn extractCurrencyAmounts(allocator: std.mem.Allocator, text: []const u8) ![]f64 {
    // Matches: $123.45, $1,234.56, USD 100.00
    var regex = try zregex.Regex.compile(allocator,
        "(?:USD|\\$)\\s*(\\d{1,3}(?:,\\d{3})*(?:\\.\\d{2})?)");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, text);
    defer allocator.free(matches);

    var amounts = try allocator.alloc(f64, matches.len);
    for (matches, 0..) |match, i| {
        const amount_str = match.slice(text);

        // Remove currency symbols and commas
        var clean_str = try allocator.alloc(u8, amount_str.len);
        defer allocator.free(clean_str);

        var clean_idx: usize = 0;
        for (amount_str) |char| {
            if (std.ascii.isDigit(char) or char == '.') {
                clean_str[clean_idx] = char;
                clean_idx += 1;
            }
        }

        amounts[i] = try std.fmt.parseFloat(f64, clean_str[0..clean_idx]);
    }

    return amounts;
}
```

### Credit Card Validation

```zig
pub fn validateCreditCard(allocator: std.mem.Allocator, card_number: []const u8) !bool {
    // Remove spaces and dashes
    var digits_only = try allocator.alloc(u8, card_number.len);
    defer allocator.free(digits_only);

    var digit_count: usize = 0;
    for (card_number) |char| {
        if (std.ascii.isDigit(char)) {
            digits_only[digit_count] = char;
            digit_count += 1;
        }
    }

    const clean_number = digits_only[0..digit_count];

    // Check format with regex
    var format_regex = try zregex.Regex.compile(allocator,
        "^(?:4\\d{15}|5[1-5]\\d{14}|3[47]\\d{13}|6011\\d{12})$");
    defer format_regex.deinit();

    if (!try format_regex.isMatch(clean_number)) {
        return false;
    }

    // Luhn algorithm check would go here
    return true;
}
```

## 🌐 URL Processing

### URL Validation and Parsing

```zig
const URL = struct {
    protocol: []const u8,
    domain: []const u8,
    path: []const u8,
};

pub fn parseURL(allocator: std.mem.Allocator, url: []const u8) !?URL {
    var regex = try zregex.Regex.compile(allocator,
        "^(https?)://([^/]+)(/.*)?$");
    defer regex.deinit();

    if (try regex.find(url)) |_| {
        // In a real implementation, you'd extract capture groups
        return URL{
            .protocol = "https",
            .domain = "example.com",
            .path = "/path",
        };
    }

    return null;
}

pub fn extractURLs(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var regex = try zregex.Regex.compile(allocator,
        "https?://[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}(?:/[^\\s]*)?");
    defer regex.deinit();

    const matches = try regex.findAll(allocator, text);
    defer allocator.free(matches);

    var urls = try allocator.alloc([]const u8, matches.len);
    for (matches, 0..) |match, i| {
        urls[i] = try allocator.dupe(u8, match.slice(text));
    }

    return urls;
}
```

## 📊 CSV Processing

### CSV Line Parser

```zig
pub fn parseCSVLine(allocator: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var field_regex = try zregex.Regex.compile(allocator,
        "(?:\"([^\"]*)\"|([^,]*))(?:,|$)");
    defer field_regex.deinit();

    const matches = try field_regex.findAll(allocator, line);
    defer allocator.free(matches);

    var fields = try allocator.alloc([]const u8, matches.len);
    for (matches, 0..) |match, i| {
        const field = match.slice(line);

        // Remove quotes if present
        if (field.len >= 2 and field[0] == '"' and field[field.len - 1] == '"') {
            fields[i] = try allocator.dupe(u8, field[1..field.len - 1]);
        } else {
            // Remove trailing comma if present
            const end_idx = if (field.len > 0 and field[field.len - 1] == ',')
                field.len - 1 else field.len;
            fields[i] = try allocator.dupe(u8, field[0..end_idx]);
        }
    }

    return fields;
}
```

## 🔧 Configuration File Processing

### INI File Parser

```zig
const ConfigSection = struct {
    name: []const u8,
    entries: std.StringHashMap([]const u8),
};

pub fn parseINIFile(allocator: std.mem.Allocator, content: []const u8) !std.ArrayList(ConfigSection) {
    var sections = std.ArrayList(ConfigSection).init(allocator);

    var section_regex = try zregex.Regex.compile(allocator, "^\\[([^\\]]+)\\]$");
    defer section_regex.deinit();

    var entry_regex = try zregex.Regex.compile(allocator, "^([^=]+)=(.*)$");
    defer entry_regex.deinit();

    var lines = std.mem.split(u8, content, "\n");
    var current_section: ?*ConfigSection = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') {
            continue; // Skip empty lines and comments
        }

        if (try section_regex.isMatch(trimmed)) {
            // New section
            var section = ConfigSection{
                .name = try allocator.dupe(u8, trimmed[1..trimmed.len-1]),
                .entries = std.StringHashMap([]const u8).init(allocator),
            };
            try sections.append(section);
            current_section = &sections.items[sections.items.len - 1];
        } else if (try entry_regex.isMatch(trimmed) and current_section != null) {
            // Parse key=value entry
            // In practice, you'd extract capture groups here
            // This is a simplified version
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1..], " \t");

                try current_section.?.entries.put(
                    try allocator.dupe(u8, key),
                    try allocator.dupe(u8, value)
                );
            }
        }
    }

    return sections;
}
```

## 🎯 Performance Examples

### Batch Processing

```zig
pub fn validateEmailsBatch(allocator: std.mem.Allocator, emails: [][]const u8) ![]bool {
    // Compile once, use many times
    var regex = try zregex.Regex.compile(allocator,
        "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}");
    defer regex.deinit();

    var results = try allocator.alloc(bool, emails.len);

    for (emails, 0..) |email, i| {
        results[i] = try regex.isMatch(email);
    }

    return results;
}
```

### Streaming Log Processing

```zig
pub fn processLogStream(allocator: std.mem.Allocator, reader: anytype) !void {
    var error_regex = try zregex.Regex.compile(allocator, "ERROR|FATAL");
    defer error_regex.deinit();

    var streaming = try error_regex.createStreamingMatcher(allocator);
    defer streaming.deinit();

    var buffer: [8192]u8 = undefined;
    while (try reader.readAll(&buffer)) |bytes_read| {
        if (bytes_read == 0) break;

        try streaming.feedData(buffer[0..bytes_read]);

        // Process any complete matches found so far
        const matches = streaming.getMatches();
        for (matches) |match| {
            std.debug.print("Error found at position {}-{}\n", .{match.start, match.end});
        }

        // Reset for next chunk
        try streaming.reset();
    }

    try streaming.finalize();
}
```

These examples demonstrate the versatility and power of zregex for real-world text processing tasks. Each example includes proper memory management and error handling following Zig best practices.