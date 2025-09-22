# zregex API Reference

Complete API documentation for the zregex regular expression library.

## Core Types

### `RegexError`

Error types that can be returned by zregex operations:

```zig
pub const RegexError = error{
    InvalidPattern,      // Malformed regex pattern
    CompilationFailed,   // NFA/JIT compilation failed
    MatchingFailed,      // Runtime matching error
    OutOfMemory,         // Memory allocation failed
    InvalidInput,        // Invalid input string
    UnsupportedFeature,  // Feature not yet implemented
};
```

### `Match`

Represents a successful pattern match:

```zig
pub const Match = struct {
    start: usize,           // Start position in input
    end: usize,             // End position in input
    groups: ?[]?Match,      // Capture groups (optional)

    pub fn slice(self: Match, input: []const u8) []const u8
};
```

**Methods:**
- `slice(input)` - Returns the matched substring

### `Regex`

Main regex pattern object:

```zig
pub const Regex = struct {
    pattern: []const u8,
    compiled: CompiledPattern,
    allocator: Allocator,
};
```

## Core API

### `Regex.compile(allocator, pattern)`

Compiles a regex pattern into an optimized matcher.

**Signature:**
```zig
pub fn compile(allocator: Allocator, pattern: []const u8) RegexError!Regex
```

**Parameters:**
- `allocator` - Memory allocator for pattern compilation
- `pattern` - Regex pattern string

**Returns:**
- `Regex` - Compiled regex object
- `RegexError` - On compilation failure

**Example:**
```zig
var regex = try zregex.Regex.compile(allocator, "\\d{3}-\\d{2}-\\d{4}");
defer regex.deinit();
```

### `regex.deinit()`

Frees all memory associated with the regex.

**Signature:**
```zig
pub fn deinit(self: *Regex) void
```

**Example:**
```zig
var regex = try zregex.Regex.compile(allocator, "pattern");
defer regex.deinit(); // Always call deinit
```

### `regex.isMatch(input)`

Tests if the input contains a match for the pattern.

**Signature:**
```zig
pub fn isMatch(self: *const Regex, input: []const u8) RegexError!bool
```

**Parameters:**
- `input` - Input string to test

**Returns:**
- `bool` - True if pattern matches, false otherwise
- `RegexError` - On matching failure

**Example:**
```zig
const matches = try regex.isMatch("Hello World 123");
if (matches) {
    std.debug.print("Pattern found!\n", .{});
}
```

### `regex.find(input)`

Finds the first match in the input string.

**Signature:**
```zig
pub fn find(self: *const Regex, input: []const u8) RegexError!?Match
```

**Parameters:**
- `input` - Input string to search

**Returns:**
- `?Match` - First match found, or null if no match
- `RegexError` - On matching failure

**Example:**
```zig
if (try regex.find("Call 555-123-4567")) |match| {
    std.debug.print("Found: {s}\n", .{match.slice("Call 555-123-4567")});
    std.debug.print("Position: {}-{}\n", .{match.start, match.end});
}
```

### `regex.findAll(allocator, input)`

Finds all non-overlapping matches in the input.

**Signature:**
```zig
pub fn findAll(self: *const Regex, allocator: Allocator, input: []const u8) RegexError![]Match
```

**Parameters:**
- `allocator` - Allocator for result array
- `input` - Input string to search

**Returns:**
- `[]Match` - Array of all matches found
- `RegexError` - On matching failure

**Example:**
```zig
const matches = try regex.findAll(allocator, "Call 555-123-4567 or 555-987-6543");
defer allocator.free(matches);

for (matches) |match| {
    std.debug.print("Found: {s}\n", .{match.slice(input)});
}
```

## Streaming API

### `regex.createStreamingMatcher(allocator)`

Creates a streaming matcher for incremental processing.

**Signature:**
```zig
pub fn createStreamingMatcher(self: *const Regex, allocator: Allocator) RegexError!StreamingMatcher
```

**Parameters:**
- `allocator` - Allocator for streaming state

**Returns:**
- `StreamingMatcher` - Streaming matcher instance
- `RegexError` - On creation failure

### `StreamingMatcher`

Handles incremental pattern matching:

```zig
pub const StreamingMatcher = struct {
    pub fn deinit(self: *StreamingMatcher) void
    pub fn feedData(self: *StreamingMatcher, data: []const u8) RegexError!void
    pub fn finalize(self: *StreamingMatcher) RegexError!void
    pub fn getMatches(self: *const StreamingMatcher) []const Match
    pub fn reset(self: *StreamingMatcher) RegexError!void
};
```

**Example:**
```zig
var streaming = try regex.createStreamingMatcher(allocator);
defer streaming.deinit();

try streaming.feedData("chunk1 ");
try streaming.feedData("pattern ");
try streaming.feedData("chunk2");
try streaming.finalize();

const matches = streaming.getMatches();
```

## Pattern Syntax

### Basic Patterns

| Pattern | Description | Example |
|---------|-------------|---------|
| `abc` | Literal string | Matches "abc" exactly |
| `.` | Any character | `a.c` matches "abc", "axc" |
| `\n` | Newline | Matches newline character |
| `\t` | Tab | Matches tab character |
| `\r` | Carriage return | Matches CR character |

### Quantifiers

| Pattern | Description | Example |
|---------|-------------|---------|
| `*` | Zero or more | `ab*` matches "a", "ab", "abbb" |
| `+` | One or more | `ab+` matches "ab", "abbb" |
| `?` | Zero or one | `ab?` matches "a", "ab" |
| `{n}` | Exactly n | `a{3}` matches "aaa" |
| `{n,}` | n or more | `a{2,}` matches "aa", "aaa", "aaaa" |
| `{n,m}` | Between n and m | `a{2,4}` matches "aa", "aaa", "aaaa" |

### Character Classes

| Pattern | Description | Example |
|---------|-------------|---------|
| `[abc]` | Character set | Matches 'a', 'b', or 'c' |
| `[^abc]` | Negated set | Matches anything except 'a', 'b', 'c' |
| `[a-z]` | Character range | Matches lowercase letters |
| `[A-Z]` | Character range | Matches uppercase letters |
| `[0-9]` | Character range | Matches digits |

### Predefined Classes

| Pattern | Description | Equivalent |
|---------|-------------|------------|
| `\d` | Digits | `[0-9]` |
| `\D` | Non-digits | `[^0-9]` |
| `\w` | Word characters | `[a-zA-Z0-9_]` |
| `\W` | Non-word characters | `[^a-zA-Z0-9_]` |
| `\s` | Whitespace | `[ \t\r\n\f\v]` |
| `\S` | Non-whitespace | `[^ \t\r\n\f\v]` |

### Anchors

| Pattern | Description | Example |
|---------|-------------|---------|
| `^` | Start of string | `^hello` matches "hello world" |
| `$` | End of string | `world$` matches "hello world" |

### Groups and Alternation

| Pattern | Description | Example |
|---------|-------------|---------|
| `(abc)` | Group | Groups characters together |
| `|` | Alternation | `cat|dog` matches "cat" or "dog" |

## Error Handling

All zregex functions return `RegexError` for error conditions:

```zig
const regex = zregex.Regex.compile(allocator, "invalid[") catch |err| switch (err) {
    error.InvalidPattern => {
        std.debug.print("Invalid regex pattern\n", .{});
        return;
    },
    error.OutOfMemory => {
        std.debug.print("Out of memory\n", .{});
        return;
    },
    else => return err,
};
```

## Memory Management

zregex uses explicit memory management:

1. **Always call `deinit()`** on regex objects
2. **Free match arrays** from `findAll()`
3. **Use defer** for automatic cleanup
4. **Check for leaks** with GeneralPurposeAllocator

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit(); // Reports leaks
const allocator = gpa.allocator();

var regex = try zregex.Regex.compile(allocator, "pattern");
defer regex.deinit(); // Required

const matches = try regex.findAll(allocator, "input");
defer allocator.free(matches); // Required
```

## Performance Tips

1. **Reuse compiled regexes** - Compilation is expensive
2. **Use `isMatch()`** when you only need boolean result
3. **Consider streaming** for large inputs
4. **Profile your patterns** - Some patterns are faster than others
5. **Enable optimizations** - Use ReleaseFast for production

## Thread Safety

zregex objects are **not** thread-safe by design:

- ✅ Multiple threads can use **different** regex objects
- ❌ Multiple threads **cannot** share the same regex object
- ✅ Compiled regexes are **read-only** after compilation
- ❌ Streaming matchers maintain **mutable state**

For multi-threaded use, create separate regex instances per thread.

## Examples

### Email Validation

```zig
var email_regex = try zregex.Regex.compile(allocator,
    "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}");
defer email_regex.deinit();

const is_valid = try email_regex.isMatch("user@example.com");
```

### Phone Number Extraction

```zig
var phone_regex = try zregex.Regex.compile(allocator,
    "\\(\\d{3}\\)\\s*\\d{3}-\\d{4}");
defer phone_regex.deinit();

const phones = try phone_regex.findAll(allocator,
    "Call (555) 123-4567 or (555) 987-6543");
defer allocator.free(phones);
```

### Log Parsing

```zig
var log_regex = try zregex.Regex.compile(allocator,
    "\\[(\\d{4}-\\d{2}-\\d{2})\\]\\s+(ERROR|WARN|INFO)\\s+(.+)");
defer log_regex.deinit();

var streaming = try log_regex.createStreamingMatcher(allocator);
defer streaming.deinit();

// Process log file in chunks
while (try readChunk(file)) |chunk| {
    try streaming.feedData(chunk);
}
try streaming.finalize();
```