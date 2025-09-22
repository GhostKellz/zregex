# Contributing to zregex

Thank you for your interest in contributing to zregex! This document provides guidelines and information for contributors.

## 🚀 Getting Started

### Prerequisites

- Zig 0.16.0-dev or later
- Git
- Basic understanding of regular expressions and finite automata

### Setting up the Development Environment

1. Fork the repository on GitHub
2. Clone your fork locally:
   ```bash
   git clone https://github.com/YOUR_USERNAME/zregex.git
   cd zregex
   ```
3. Build and test:
   ```bash
   zig build test
   ```

## 📝 Development Guidelines

### Code Style

- Follow Zig's official style guide
- Use 4 spaces for indentation
- Keep lines under 100 characters when practical
- Use descriptive variable and function names
- Add documentation comments for public APIs

### Code Organization

```
src/
├── root.zig          # Main API and Regex struct
├── parser.zig        # Pattern parsing and AST generation
├── nfa_builder.zig   # NFA construction from AST
├── matcher.zig       # NFA-based pattern matching
├── streaming.zig     # Streaming/incremental matching
├── jit.zig          # JIT compilation and execution
├── unicode.zig       # Unicode support and character classes
└── main.zig         # Library entry point
```

### Testing

- All new features must include tests
- Run the full test suite: `zig build test`
- Ensure no memory leaks with Zig's GeneralPurposeAllocator
- Add performance tests for performance-critical changes

### Documentation

- Update README.md for user-facing changes
- Add inline documentation for new public APIs
- Update this guide for development process changes

## 🐛 Bug Reports

When reporting bugs, please include:

1. **Zig version**: Output of `zig version`
2. **Platform**: OS and architecture
3. **Minimal reproduction**: Smallest code that demonstrates the issue
4. **Expected behavior**: What you expected to happen
5. **Actual behavior**: What actually happened
6. **Stack trace**: If applicable

### Bug Report Template

```markdown
**Zig Version:** 0.16.0-dev
**Platform:** Linux x86_64
**zregex Version:** main/commit-hash

**Description:**
Brief description of the issue.

**Reproduction:**
```zig
const std = @import("std");
const zregex = @import("zregex");

// Minimal code that reproduces the issue
```

**Expected:** Expected behavior
**Actual:** Actual behavior
**Stack Trace:** (if applicable)
```

## ✨ Feature Requests

We welcome feature requests! Please:

1. Check existing issues to avoid duplicates
2. Describe the use case and motivation
3. Provide examples of the proposed API
4. Consider backward compatibility

### Feature Categories

**High Priority:**
- Performance improvements
- Memory usage optimizations
- Standards compliance (PCRE, POSIX)
- Critical bug fixes

**Medium Priority:**
- Additional regex features
- API ergonomics improvements
- Better error messages
- Documentation improvements

**Low Priority:**
- Nice-to-have features
- Advanced optimizations
- Experimental features

## 🔧 Pull Requests

### Before Submitting

1. Ensure all tests pass: `zig build test`
2. Run with optimizations: `zig build -Doptimize=ReleaseFast`
3. Check for memory leaks
4. Update documentation if needed
5. Add tests for new functionality

### PR Guidelines

1. **One feature per PR**: Keep changes focused
2. **Clear description**: Explain what and why
3. **Reference issues**: Link to related issues
4. **Update tests**: Include comprehensive test coverage
5. **Update docs**: Keep documentation current

### PR Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Performance improvement
- [ ] Documentation update
- [ ] Refactoring

## Testing
- [ ] All existing tests pass
- [ ] New tests added for new functionality
- [ ] Manual testing performed
- [ ] No memory leaks detected

## Related Issues
Fixes #123, Related to #456

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] Tests added/updated
```

## 🏗️ Architecture Overview

### Core Components

1. **Parser** (`parser.zig`)
   - Lexical analysis and tokenization
   - AST construction
   - Syntax validation

2. **NFA Builder** (`nfa_builder.zig`)
   - Thompson's construction algorithm
   - Epsilon transition handling
   - State optimization

3. **Matcher** (`matcher.zig`)
   - NFA simulation
   - Backtracking implementation
   - Match result construction

4. **JIT Compiler** (`jit.zig`)
   - Bytecode generation
   - Instruction optimization
   - Runtime execution

### Performance Considerations

- **Memory allocation**: Minimize allocations in hot paths
- **String copying**: Use slices where possible
- **Cache locality**: Keep related data together
- **Branching**: Minimize unpredictable branches

### Adding New Features

#### New Regex Operators

1. Add to AST in `parser.zig`
2. Implement parsing logic
3. Add NFA construction in `nfa_builder.zig`
4. Update matcher if needed
5. Add comprehensive tests

#### Performance Optimizations

1. Profile existing code
2. Identify bottlenecks
3. Implement optimization
4. Benchmark before/after
5. Ensure correctness maintained

## 🧪 Testing Strategy

### Test Categories

1. **Unit Tests**: Individual component testing
2. **Integration Tests**: Full pipeline testing
3. **Regression Tests**: Previous bug verification
4. **Performance Tests**: Speed and memory benchmarks
5. **Fuzz Tests**: Random input testing

### Test Naming

```zig
test "component: specific behavior description" {
    // Test implementation
}
```

### Memory Testing

Always test with leak detection:

```zig
test "feature with memory management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test code that uses allocator
}
```

## 📚 Learning Resources

### Regular Expressions
- [RegexOne Interactive Tutorial](https://regexone.com/)
- [Regular-Expressions.info](https://www.regular-expressions.info/)
- [Mastering Regular Expressions by Jeffrey Friedl](https://www.oreilly.com/library/view/mastering-regular-expressions/0596528124/)

### Finite Automata
- [Sipser's Introduction to the Theory of Computation](https://math.mit.edu/~sipser/book.html)
- [Dragon Book - Compilers: Principles, Techniques, and Tools](https://suif.stanford.edu/dragonbook/)

### Zig Language
- [Official Zig Documentation](https://ziglang.org/documentation/)
- [Zig Learn](https://ziglearn.org/)
- [Zig by Example](https://zig-by-example.com/)

## 🤝 Community

### Communication

- **GitHub Issues**: Bug reports and feature requests
- **GitHub Discussions**: General questions and ideas
- **Discord**: Real-time community chat (link in main README)

### Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help others learn and grow
- Maintain professionalism

## 📋 Development Checklist

### Before Committing
- [ ] Code compiles without warnings
- [ ] All tests pass
- [ ] No memory leaks detected
- [ ] Code follows style guidelines
- [ ] Documentation updated if needed

### Before Submitting PR
- [ ] Branch is up to date with main
- [ ] Comprehensive testing completed
- [ ] PR description is clear and complete
- [ ] Related issues are referenced
- [ ] Breaking changes are documented

## 🎯 Future Roadmap

### Short Term (v0.1)
- [ ] Complete regex feature parity with PCRE subset
- [ ] Performance optimization
- [ ] Comprehensive documentation
- [ ] Stable API

### Medium Term (v0.2)
- [ ] Advanced optimizations (DFA construction)
- [ ] Capture groups support
- [ ] Look-ahead/look-behind assertions
- [ ] Unicode property support

### Long Term (v1.0)
- [ ] Full PCRE compatibility
- [ ] JIT compilation maturity
- [ ] Multi-threading support
- [ ] Language bindings

Thank you for contributing to zregex! 🎉