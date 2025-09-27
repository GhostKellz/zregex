const std = @import("std");
const Allocator = std.mem.Allocator;

/// Configuration for streaming regex matching
pub const StreamingConfig = struct {
    /// Size of the internal buffer for chunk processing
    buffer_size: usize = 4096,

    /// Maximum number of buffers to keep in the pool
    pool_size: usize = 8,

    /// Enable partial match recovery on chunk boundaries
    partial_match_recovery: bool = true,

    /// Maximum lookahead for cross-boundary matches
    max_lookahead: usize = 256,

    /// Memory usage limit for the streaming matcher (0 = unlimited)
    memory_limit: usize = 0,

    /// Whether to track match boundaries across chunks
    track_boundaries: bool = true,

    pub fn default() StreamingConfig {
        return StreamingConfig{};
    }

    pub fn withBufferSize(self: StreamingConfig, size: usize) StreamingConfig {
        var config = self;
        config.buffer_size = size;
        return config;
    }

    pub fn withPoolSize(self: StreamingConfig, size: usize) StreamingConfig {
        var config = self;
        config.pool_size = size;
        return config;
    }

    pub fn withMemoryLimit(self: StreamingConfig, limit: usize) StreamingConfig {
        var config = self;
        config.memory_limit = limit;
        return config;
    }
};

/// Memory pool for buffer management
pub const BufferPool = struct {
    allocator: Allocator,
    buffers: std.ArrayList([]u8),
    available: std.ArrayList(bool),
    buffer_size: usize,
    max_buffers: usize,

    pub fn init(allocator: Allocator, buffer_size: usize, max_buffers: usize) BufferPool {
        return BufferPool{
            .allocator = allocator,
            .buffers = std.ArrayList([]u8){},
            .available = std.ArrayList(bool){},
            .buffer_size = buffer_size,
            .max_buffers = max_buffers,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        for (self.buffers.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.buffers.deinit(self.allocator);
        self.available.deinit(self.allocator);
    }

    pub fn acquire(self: *BufferPool) ![]u8 {
        // Look for an available buffer
        for (self.available.items, 0..) |avail, i| {
            if (avail) {
                self.available.items[i] = false;
                return self.buffers.items[i];
            }
        }

        // Create a new buffer if under the limit
        if (self.buffers.items.len < self.max_buffers) {
            const buffer = try self.allocator.alloc(u8, self.buffer_size);
            try self.buffers.append(self.allocator, buffer);
            try self.available.append(self.allocator, false);
            return buffer;
        }

        // All buffers in use and at max capacity
        return error.NoBuffersAvailable;
    }

    pub fn release(self: *BufferPool, buffer: []u8) void {
        for (self.buffers.items, 0..) |buf, i| {
            if (buf.ptr == buffer.ptr) {
                self.available.items[i] = true;
                return;
            }
        }
    }

    pub fn reset(self: *BufferPool) void {
        for (self.available.items) |*avail| {
            avail.* = true;
        }
    }
};

/// Enhanced streaming matcher with configuration and pooling
pub const EnhancedStreamingMatcher = struct {
    allocator: Allocator,
    config: StreamingConfig,
    buffer_pool: BufferPool,
    active_buffer: ?[]u8 = null,
    lookahead_buffer: ?[]u8 = null,
    partial_matches: std.ArrayList(PartialMatch),
    memory_usage: usize = 0,

    const PartialMatch = struct {
        start_pos: usize,
        current_pos: usize,
        states: std.ArrayList(u32),
        chunk_id: usize,
    };

    pub fn init(allocator: Allocator, config: StreamingConfig) !EnhancedStreamingMatcher {
        var buffer_pool = BufferPool.init(allocator, config.buffer_size, config.pool_size);
        errdefer buffer_pool.deinit();

        return EnhancedStreamingMatcher{
            .allocator = allocator,
            .config = config,
            .buffer_pool = buffer_pool,
            .partial_matches = std.ArrayList(PartialMatch){},
        };
    }

    pub fn deinit(self: *EnhancedStreamingMatcher) void {
        if (self.active_buffer) |buffer| {
            self.buffer_pool.release(buffer);
        }
        if (self.lookahead_buffer) |buffer| {
            self.buffer_pool.release(buffer);
        }
        for (self.partial_matches.items) |*partial| {
            partial.states.deinit(self.allocator);
        }
        self.partial_matches.deinit(self.allocator);
        self.buffer_pool.deinit();
    }

    pub fn feedChunk(self: *EnhancedStreamingMatcher, data: []const u8) !void {
        // Check memory limit
        if (self.config.memory_limit > 0 and self.memory_usage + data.len > self.config.memory_limit) {
            return error.MemoryLimitExceeded;
        }

        // Acquire buffer if needed
        if (self.active_buffer == null) {
            self.active_buffer = try self.buffer_pool.acquire();
        }

        const buffer = self.active_buffer.?;

        // Process data in chunks
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk_size = @min(self.config.buffer_size, data.len - offset);
            const chunk = data[offset .. offset + chunk_size];

            // Copy to buffer
            @memcpy(buffer[0..chunk_size], chunk);

            // Process chunk with partial match recovery
            if (self.config.partial_match_recovery) {
                try self.processWithRecovery(buffer[0..chunk_size]);
            } else {
                try self.processChunk(buffer[0..chunk_size]);
            }

            offset += chunk_size;
        }

        self.memory_usage += data.len;
    }

    fn processWithRecovery(self: *EnhancedStreamingMatcher, chunk: []const u8) !void {
        // Save partial matches at chunk boundaries
        if (self.config.max_lookahead > 0) {
            // Keep lookahead buffer for cross-boundary matching
            if (self.lookahead_buffer == null) {
                self.lookahead_buffer = try self.buffer_pool.acquire();
            }

            const lookahead_size = @min(chunk.len, self.config.max_lookahead);
            const lookahead = self.lookahead_buffer.?;
            @memcpy(lookahead[0..lookahead_size], chunk[chunk.len - lookahead_size ..]);
        }

        // Continue processing partial matches from previous chunks
        var i: usize = 0;
        while (i < self.partial_matches.items.len) {
            var partial = &self.partial_matches.items[i];
            // Process continuation of partial match
            // This would integrate with the actual matcher logic
            _ = partial;
            i += 1;
        }
    }

    fn processChunk(self: *EnhancedStreamingMatcher, chunk: []const u8) !void {
        // Basic chunk processing without recovery
        _ = self;
        _ = chunk;
        // This would integrate with the actual matcher logic
    }

    pub fn finalize(self: *EnhancedStreamingMatcher) !void {
        // Process any remaining partial matches
        for (self.partial_matches.items) |*partial| {
            // Finalize partial matches
            _ = partial;
        }

        // Release buffers back to pool
        if (self.active_buffer) |buffer| {
            self.buffer_pool.release(buffer);
            self.active_buffer = null;
        }
        if (self.lookahead_buffer) |buffer| {
            self.buffer_pool.release(buffer);
            self.lookahead_buffer = null;
        }
    }

    pub fn getMemoryUsage(self: *const EnhancedStreamingMatcher) usize {
        return self.memory_usage;
    }
};

test "buffer pool management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var pool = BufferPool.init(allocator, 1024, 4);
    defer pool.deinit();

    // Acquire and release buffers
    const buf1 = try pool.acquire();
    const buf2 = try pool.acquire();

    try std.testing.expect(buf1.len == 1024);
    try std.testing.expect(buf2.len == 1024);

    pool.release(buf1);

    // Should reuse buf1
    const buf3 = try pool.acquire();
    try std.testing.expect(buf3.ptr == buf1.ptr);

    pool.release(buf2);
    pool.release(buf3);
}

test "streaming config builder" {
    const config = StreamingConfig.default()
        .withBufferSize(8192)
        .withPoolSize(16)
        .withMemoryLimit(1024 * 1024); // 1MB

    try std.testing.expect(config.buffer_size == 8192);
    try std.testing.expect(config.pool_size == 16);
    try std.testing.expect(config.memory_limit == 1024 * 1024);
}

test "enhanced streaming with memory limit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = StreamingConfig.default()
        .withBufferSize(256)
        .withMemoryLimit(512);

    var matcher = try EnhancedStreamingMatcher.init(allocator, config);
    defer matcher.deinit();

    // Should succeed
    const small_data = "test";
    try matcher.feedChunk(small_data);

    // Create data that would exceed limit
    const large_data = [_]u8{'x'} ** 600;

    // Should fail due to memory limit
    const result = matcher.feedChunk(&large_data);
    try std.testing.expectError(error.MemoryLimitExceeded, result);
}