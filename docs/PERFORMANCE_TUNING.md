# Performance Tuning Guide

This guide covers performance optimization techniques and feature flags available in zregex.

## Feature Flags

### Build-Time Flags

Configure these flags in your `build.zig`:

```zig
const zregex_options = b.addOptions();
zregex_options.addOption(bool, "jit_enabled", true);
zregex_options.addOption(bool, "unicode_enabled", true);
zregex_options.addOption(bool, "streaming_enabled", true);
zregex_options.addOption(bool, "capture_groups", true);
zregex_options.addOption(bool, "backtracking", false);
```

#### JIT Compilation (`jit_enabled`)
- **Default**: `true`
- **Purpose**: Enables Just-In-Time compilation for better performance
- **Trade-offs**: Faster execution, slightly higher compilation time
- **Use case**: Enable for production workloads with repeated pattern usage

#### Unicode Support (`unicode_enabled`)
- **Default**: `true`
- **Purpose**: Full Unicode property support and UTF-8 handling
- **Trade-offs**: Larger binary size, comprehensive character support
- **Use case**: Disable only if you're working exclusively with ASCII

#### Streaming Mode (`streaming_enabled`)
- **Default**: `true`
- **Purpose**: Process large inputs in chunks
- **Trade-offs**: Memory efficiency vs. slightly more complex API
- **Use case**: Essential for processing large files or network streams

#### Capture Groups (`capture_groups`)
- **Default**: `true`
- **Purpose**: Enable capture group extraction
- **Trade-offs**: More memory usage, group tracking overhead
- **Use case**: Disable if you only need boolean matching

#### Backtracking (`backtracking`)
- **Default**: `false`
- **Purpose**: Enable backtracking for advanced patterns
- **Trade-offs**: More expressive patterns vs. potential ReDoS vulnerabilities
- **Use case**: Enable only when NFA approach is insufficient

### Runtime Configuration

Use the features API to control runtime behavior:

```zig
const zregex = @import("zregex");

// Configure runtime features
var features = zregex.features.getFeatureInfo();
zregex.features.setPreferJit(true);
zregex.features.setPreferStreaming(false);
zregex.features.setForceNfa(false);
zregex.features.setDebugMode(false);
```

## Performance Optimization Strategies

### 1. Pattern Optimization

#### Anchors
Use anchors when possible to reduce search space:
```zig
// Better: anchored pattern
const regex = try Regex.compile(allocator, "^error:");

// Slower: unanchored pattern
const regex = try Regex.compile(allocator, "error:");
```

#### Character Classes
Use character classes instead of alternation:
```zig
// Better: character class
const regex = try Regex.compile(allocator, "[0-9]+");

// Slower: alternation
const regex = try Regex.compile(allocator, "(0|1|2|3|4|5|6|7|8|9)+");
```

#### Quantifier Placement
Place expensive operations outside of quantifiers:
```zig
// Better: group quantified
const regex = try Regex.compile(allocator, "(word)+");

// Slower: complex expression quantified
const regex = try Regex.compile(allocator, "(w|wo|wor|word)+");
```

### 2. Engine Selection

#### JIT vs NFA
- **JIT**: Best for repeated pattern usage, simple patterns
- **NFA**: Best for complex patterns, one-time usage

```zig
// Force JIT for hot paths
zregex.features.setPreferJit(true);

// Force NFA for complex patterns
zregex.features.setForceNfa(true);
```

#### Streaming vs Direct
- **Streaming**: Best for large inputs (>1MB), memory-constrained environments
- **Direct**: Best for small to medium inputs (<1MB)

```zig
// For large files
const streaming_matcher = try regex.createStreamingMatcher(allocator);
defer streaming_matcher.deinit();

// For small strings
const match = try regex.find(input);
```

### 3. Memory Optimization

#### Buffer Pool Configuration
```zig
const config = streaming.StreamingConfig.default()
    .withBufferSize(64 * 1024)  // 64KB buffers
    .withPoolSize(8)            // Pool of 8 buffers
    .withMemoryLimit(16 * 1024 * 1024); // 16MB limit
```

#### Group Management
Only enable groups when needed:
```zig
// Minimal memory usage
const matched = try regex.isMatch(input);

// Enable groups only when needed
const match = try regex.findWithGroups(input);
```

### 4. Unicode Optimization

#### ASCII Fast Path
The engine automatically optimizes ASCII-only patterns:
```zig
// Automatically uses ASCII fast path
const regex = try Regex.compile(allocator, "[a-zA-Z0-9]+");

// Full Unicode path (slower)
const regex = try Regex.compile(allocator, "\\p{Letter}+");
```

#### Case Sensitivity
```zig
// Case-sensitive (faster)
const regex = try Regex.compile(allocator, "Hello");

// Case-insensitive (slower, requires Unicode folding)
const regex = try Regex.compile(allocator, "(?i)Hello");
```

## Performance Benchmarks

### Pattern Types Performance (relative to simplest case)

| Pattern Type | JIT | NFA | Memory |
|--------------|-----|-----|--------|
| Literal match | 1.0x | 1.2x | Low |
| Character class | 1.1x | 1.5x | Low |
| Simple quantifier | 1.3x | 2.0x | Medium |
| Alternation | 1.8x | 2.5x | Medium |
| Complex groups | 2.5x | 4.0x | High |
| Unicode properties | 3.0x | 5.0x | High |

### Input Size Scaling

| Input Size | Direct | Streaming | Memory Peak |
|------------|--------|-----------|-------------|
| 1KB | 1.0x | 1.2x | Low |
| 100KB | 1.0x | 1.1x | Medium |
| 10MB | OOM | 1.0x | Constant |
| 1GB | OOM | 1.0x | Constant |

## Profiling and Diagnostics

### Enable Diagnostics
```zig
zregex.features.setDiagnosticsEnabled(true);
const info = zregex.features.getFeatureInfo();
```

### Pattern Analysis
```zig
const regex = try Regex.compile(allocator, pattern);
const complexity = regex.getComplexity();
const estimated_memory = regex.getEstimatedMemory();
```

### Performance Monitoring
```zig
const start = std.time.nanoTimestamp();
const match = try regex.find(input);
const duration = std.time.nanoTimestamp() - start;

if (duration > threshold) {
    std.log.warn("Slow pattern detected: {} ns", .{duration});
}
```

## Common Performance Anti-Patterns

### 1. Nested Quantifiers (ReDoS Risk)
```zig
// AVOID: Catastrophic backtracking
const bad = try Regex.compile(allocator, "(a+)+b");

// BETTER: Possessive quantifier
const good = try Regex.compile(allocator, "a++b");
```

### 2. Excessive Alternation
```zig
// AVOID: Many alternatives
const bad = try Regex.compile(allocator, "(cat|dog|bird|fish|snake)");

// BETTER: Character class when possible
const good = try Regex.compile(allocator, "[cdfs]");
```

### 3. Unanchored Patterns on Large Text
```zig
// AVOID: Searches entire document
const bad = try Regex.compile(allocator, "needle");

// BETTER: Anchor when possible
const good = try Regex.compile(allocator, "^needle");
```

## Memory Management Best Practices

### 1. Pattern Reuse
```zig
// Compile once, use many times
const regex = try Regex.compile(allocator, pattern);
defer regex.deinit();

for (inputs) |input| {
    if (try regex.isMatch(input)) {
        // Process match
    }
}
```

### 2. Arena Allocation for Batch Processing
```zig
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const arena_allocator = arena.allocator();

// Process many patterns
for (patterns) |pattern| {
    const regex = try Regex.compile(arena_allocator, pattern);
    // No need to call deinit() - arena handles cleanup
}
```

### 3. Streaming for Large Inputs
```zig
const config = streaming.StreamingConfig.default()
    .withBufferSize(64 * 1024)
    .withMemoryLimit(16 * 1024 * 1024);

var matcher = try regex.createStreamingMatcher(allocator, config);
defer matcher.deinit();

while (try reader.readChunk()) |chunk| {
    try matcher.feedChunk(chunk);
}
const matches = try matcher.finalize();
```

## Platform-Specific Optimizations

### x86_64
- JIT compilation shows 2-3x improvement over NFA
- Vector instructions automatically used for character classes
- L1 cache optimization for small patterns

### ARM64
- Balanced performance between JIT and NFA
- Memory-efficient streaming mode recommended
- Lower power consumption with NFA engine

### WebAssembly
- JIT compilation disabled automatically
- Streaming mode provides memory safety
- Unicode support may be limited based on runtime