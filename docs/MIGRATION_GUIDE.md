# Migration Guide from PCRE/RE2 to zregex

This guide helps you migrate from PCRE, PCRE2, or RE2 to zregex, covering syntax differences, feature mappings, and performance considerations.

## Quick Reference

### Basic Migration Checklist

- [ ] Review pattern syntax differences
- [ ] Update API calls and error handling
- [ ] Configure build flags for needed features
- [ ] Test with your specific patterns
- [ ] Benchmark performance with your workload

## API Migration

### PCRE to zregex

#### Pattern Compilation
```c
// PCRE
pcre2_code *re = pcre2_compile(pattern, PCRE2_ZERO_TERMINATED, 0,
                               &errorcode, &erroroffset, NULL);

// zregex
var regex = try zregex.Regex.compile(allocator, pattern);
defer regex.deinit();
```

#### Matching
```c
// PCRE
int rc = pcre2_match(re, subject, subject_length, 0, 0, match_data, NULL);

// zregex
const match_result = try regex.find(input);
if (match_result) |match| {
    // Process match
}
```

#### Capture Groups
```c
// PCRE
PCRE2_SIZE *ovector = pcre2_get_ovector_pointer(match_data);
PCRE2_SPTR substring_start = subject + ovector[2*i];
PCRE2_SIZE substring_length = ovector[2*i+1] - ovector[2*i];

// zregex
if (match.groups) |groups| {
    if (groups[i]) |group| {
        const group_text = group.slice(input);
    }
}
```

### RE2 to zregex

#### C++ API
```cpp
// RE2
RE2 pattern(regex_string);
if (!pattern.ok()) {
    // Handle error
}

std::string input = "...";
if (RE2::PartialMatch(input, pattern)) {
    // Match found
}

// zregex
var regex = zregex.Regex.compile(allocator, pattern_string) catch |err| {
    // Handle error
    return err;
};
defer regex.deinit();

const matched = try regex.isMatch(input);
```

#### Capture Groups
```cpp
// RE2
std::string s1, s2;
if (RE2::FullMatch(input, pattern, &s1, &s2)) {
    // s1 and s2 contain captures
}

// zregex
const match = try regex.find(input);
if (match) |m| {
    if (m.groups) |groups| {
        const group1 = groups[1];
        const group2 = groups[2];
    }
}
```

## Pattern Syntax Differences

### Supported Features

| Feature | PCRE | RE2 | zregex | Notes |
|---------|------|-----|--------|-------|
| Basic literals | ✓ | ✓ | ✓ | Full compatibility |
| Character classes | ✓ | ✓ | ✓ | Full compatibility |
| Quantifiers | ✓ | ✓ | ✓ | Full compatibility |
| Anchors | ✓ | ✓ | ✓ | Full compatibility |
| Groups | ✓ | ✓ | ✓ | Full compatibility |
| Alternation | ✓ | ✓ | ✓ | Full compatibility |
| Unicode properties | ✓ | ✓ | ✓ | Subset implemented |
| Backreferences | ✓ | ✗ | ✗ | Not implemented |
| Lookarounds | ✓ | ✗ | ✗ | Not implemented |
| Recursion | ✓ | ✗ | ✗ | Not implemented |

### Pattern Conversion Examples

#### Character Classes
```regex
# All engines - identical
[a-zA-Z0-9]
[^0-9]
\d \w \s

# Unicode properties
\p{Letter}          # zregex: ✓ (subset)
\p{Script=Latin}    # zregex: ✓ (subset)
\p{Block=Basic_Latin} # zregex: ✗ (not implemented)
```

#### Quantifiers
```regex
# Identical in all engines
a+      # One or more
a*      # Zero or more
a?      # Zero or one
a{3,5}  # Between 3 and 5

# Possessive quantifiers (PCRE only)
a++     # PCRE: ✓, RE2: ✗, zregex: ✗
a*+     # PCRE: ✓, RE2: ✗, zregex: ✗
```

#### Groups
```regex
# Capturing groups - identical
(abc)
(a)(b)(c)

# Non-capturing groups - identical
(?:abc)

# Named groups
(?<name>abc)    # PCRE: ✓, RE2: ✓, zregex: ✗
(?P<name>abc)   # PCRE: ✓, RE2: ✓, zregex: ✗
```

#### Assertions
```regex
# Anchors - identical
^abc$
\b\w+\b

# Lookarounds - not supported in zregex/RE2
(?=abc)     # Positive lookahead - PCRE only
(?!abc)     # Negative lookahead - PCRE only
(?<=abc)    # Positive lookbehind - PCRE only
(?<!abc)    # Negative lookbehind - PCRE only
```

### Unsupported PCRE Features

These PCRE features are not available in zregex and require pattern rewriting:

#### Backreferences
```regex
# PCRE (not supported in zregex)
(word) \1       # Match repeated word

# Alternative approach
(word) word     # Explicit repetition
```

#### Recursive Patterns
```regex
# PCRE (not supported in zregex)
\(([^()]|(?R))*\)   # Balanced parentheses

# Alternative: Use a proper parser for complex structures
```

#### Conditional Patterns
```regex
# PCRE (not supported in zregex)
(a)?(?(1)b|c)   # If group 1 matches, then b, else c

# Alternative: Use separate patterns or alternation
```

## Performance Migration

### Memory Usage

| Engine | Small Patterns | Large Patterns | Memory Model |
|--------|----------------|----------------|--------------|
| PCRE | Low | High | Backtracking |
| RE2 | Medium | Medium | Automaton |
| zregex | Low-Medium | Medium | Hybrid |

### Execution Speed

| Pattern Type | PCRE | RE2 | zregex |
|--------------|------|-----|--------|
| Simple literals | Fast | Fastest | Fast |
| Character classes | Fast | Fast | Fast |
| Complex alternation | Slow | Fast | Fast |
| Unicode | Medium | Fast | Fast |

### Recommended Settings by Use Case

#### Web Input Validation (Security Critical)
```zig
// Disable backtracking to prevent ReDoS
const build_options = .{
    .backtracking = false,
    .jit_enabled = true,
    .unicode_enabled = true,
};

// Runtime safety
zregex.features.setForceNfa(true);
```

#### Log Processing (Performance Critical)
```zig
const build_options = .{
    .jit_enabled = true,
    .streaming_enabled = true,
    .capture_groups = false, // If not needed
};

// Use streaming for large logs
const streaming_matcher = try regex.createStreamingMatcher(allocator);
```

#### Text Search (Memory Critical)
```zig
const build_options = .{
    .streaming_enabled = true,
    .jit_enabled = false, // Save memory
};

const config = streaming.StreamingConfig.default()
    .withBufferSize(4096)
    .withMemoryLimit(1024 * 1024);
```

## Common Migration Issues

### 1. Error Handling

#### PCRE Error Codes
```c
// PCRE
if (errorcode != 0) {
    PCRE2_UCHAR buffer[256];
    pcre2_get_error_message(errorcode, buffer, sizeof(buffer));
}

// zregex
var regex = zregex.Regex.compile(allocator, pattern) catch |err| {
    switch (err) {
        error.InvalidPattern => std.log.err("Invalid pattern"),
        error.OutOfMemory => std.log.err("Out of memory"),
        else => std.log.err("Compilation failed: {}", .{err}),
    }
    return err;
};
```

### 2. Match Iterator Patterns

#### PCRE Global Matching
```c
// PCRE
int offset = 0;
while ((rc = pcre2_match(re, subject, subject_length, offset, 0,
                        match_data, NULL)) >= 0) {
    // Process match
    offset = ovector[1];
}

// zregex
const matches = try regex.findAll(allocator, input);
defer allocator.free(matches);
for (matches) |match| {
    // Process match
}
```

### 3. Unicode Differences

#### Case Insensitive Matching
```regex
# PCRE
(?i)hello

# zregex (manual approach)
[Hh][Ee][Ll][Ll][Oo]
```

#### Unicode Scripts
```regex
# PCRE
\p{Script=Hiragana}

# zregex
\p{Script=Hiragana}    # Supported
\p{Script=Kaithi}      # May not be supported
```

## Testing Your Migration

### 1. Pattern Compatibility Test
```zig
const test_patterns = [_][]const u8{
    "simple",
    "[a-z]+",
    "\\d{3}-\\d{2}-\\d{4}",
    "\\p{Letter}+",
    // Add your patterns here
};

for (test_patterns) |pattern| {
    var regex = zregex.Regex.compile(allocator, pattern) catch |err| {
        std.log.warn("Pattern not supported: {s} - {}", .{pattern, err});
        continue;
    };
    defer regex.deinit();

    std.log.info("Pattern supported: {s}", .{pattern});
}
```

### 2. Performance Comparison
```zig
const start = std.time.nanoTimestamp();
for (0..1000) |_| {
    _ = try regex.isMatch(test_input);
}
const duration = std.time.nanoTimestamp() - start;
std.log.info("Average time: {} ns", .{duration / 1000});
```

### 3. Memory Usage Test
```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer {
    if (gpa.deinit() == .leak) {
        std.log.warn("Memory leak detected");
    }
}
const allocator = gpa.allocator();

// Test your patterns here
```

## Feature Roadmap

### Currently Missing (may be added in future versions)
- Named capture groups
- Backreferences
- Lookahead/lookbehind assertions
- Conditional patterns
- Recursive patterns
- Some Unicode blocks/scripts

### Alternative Solutions
- **Complex parsing**: Use a dedicated parser generator
- **Named groups**: Use positional groups with documentation
- **Backreferences**: Restructure logic or use multiple passes
- **Lookarounds**: Use anchoring and multiple patterns

## Support and Resources

- **GitHub Issues**: Report migration problems
- **Documentation**: Check the API reference
- **Performance**: Use the provided benchmarking tools
- **Community**: Join discussions about migration experiences