#!/bin/bash

echo "=== zregex Performance Benchmark Suite ==="
echo ""

# Build the project first
echo "Building zregex..."
zig build -Doptimize=ReleaseFast > /dev/null 2>&1

if [ $? -ne 0 ]; then
    echo "❌ Build failed"
    exit 1
fi

echo "✅ Build successful"
echo ""

# Test patterns and inputs
declare -a patterns=(
    "hello"
    "[a-zA-Z0-9]+"
    "\\d{3}-\\d{2}-\\d{4}"
    "(cat|dog|bird)"
    "\\p{L}+"
    "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"
    "^.*(?:test|benchmark).*$"
)

declare -a inputs=(
    "hello world"
    "Hello123World456"
    "SSN: 123-45-6789"
    "I have a cat and a dog"
    "Hello世界"
    "Contact user@example.com for support"
    "This is a test string for benchmarking"
)

declare -a names=(
    "Simple Literal"
    "Character Class"
    "Complex Digits"
    "Alternation"
    "Unicode Letters"
    "Email Pattern"
    "Anchored Complex"
)

echo "=== Performance Tests ==="
echo ""

total_time=0
test_count=0

for i in "${!patterns[@]}"; do
    pattern="${patterns[$i]}"
    input="${inputs[$i]}"
    name="${names[$i]}"

    echo -n "Testing: $name... "

    # Run the test and measure time
    start_time=$(date +%s%N)
    result=$(./zig-out/bin/zregex "$pattern" "$input" 2>&1)
    end_time=$(date +%s%N)

    # Calculate time in milliseconds
    time_ns=$((end_time - start_time))
    time_ms=$((time_ns / 1000000))

    if [[ $result == *"Match found"* ]]; then
        echo "✅ ${time_ms}ms"
    elif [[ $result == *"No match"* ]]; then
        echo "✅ ${time_ms}ms (no match)"
    else
        echo "❌ Error: $result"
        continue
    fi

    total_time=$((total_time + time_ms))
    test_count=$((test_count + 1))
done

echo ""
echo "=== Summary ==="

if [ $test_count -gt 0 ]; then
    avg_time=$((total_time / test_count))
    echo "Average execution time: ${avg_time}ms"
    echo "Total tests: $test_count"

    if [ $avg_time -le 100 ]; then
        echo "✅ PASSED: Average time under 100ms target"
    else
        echo "❌ FAILED: Average time exceeds 100ms target"
    fi
else
    echo "❌ No tests completed successfully"
fi

# Memory usage test
echo ""
echo "=== Memory Usage Test ==="

# Run a memory-intensive pattern multiple times
echo "Running memory stress test (100 iterations)..."

for i in {1..100}; do
    ./zig-out/bin/zregex "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}" "Contact user@example.com for support" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "❌ Memory test failed at iteration $i"
        exit 1
    fi
done

echo "✅ Memory stress test completed (100 iterations)"

echo ""
echo "🎯 Benchmark suite completed successfully!"