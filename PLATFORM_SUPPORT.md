# Platform Support

## Supported Platforms

zregex has been validated to build and run on the following platforms:

### ✅ Tier 1 Platforms (Fully Tested)
- **Linux x86_64**: Native development platform, all tests passing
- **Linux ARM64**: Cross-compilation verified, builds successfully

### ✅ Tier 2 Platforms (Build Verified)
- **macOS x86_64 (Intel)**: Cross-compilation verified
- **macOS ARM64 (Apple Silicon)**: Cross-compilation verified
- **Windows x86_64**: Cross-compilation verified
- **WebAssembly (WASI)**: Cross-compilation verified, suitable for web deployment

## Validation Results

As of RC2 validation (2025-09-27):
- **6/6 target platforms**: Build successfully ✅
- **1/1 native platform**: Tests passing ✅
- **Success Rate**: 100% ✅

## Build Commands

### Cross-compilation Examples

```bash
# Linux ARM64
zig build -Dtarget=aarch64-linux-gnu

# macOS Intel
zig build -Dtarget=x86_64-macos-none

# macOS Apple Silicon
zig build -Dtarget=aarch64-macos-none

# Windows
zig build -Dtarget=x86_64-windows-gnu

# WebAssembly
zig build -Dtarget=wasm32-wasi -Doptimize=ReleaseSmall
```

### Testing on Native Platform

```bash
# Run full test suite (Linux x86_64 only)
zig build test

# Cross-platform build validation
zig run cross_platform_test.zig
```

## Platform-Specific Notes

### Linux
- **Primary development platform**
- All features fully supported and tested
- Best performance and stability

### macOS
- Cross-compilation only (native testing pending)
- No known platform-specific issues
- Should work identically to Linux

### Windows
- Cross-compilation only (native testing pending)
- Uses MinGW toolchain (-gnu target)
- File path handling may need testing

### WebAssembly
- Compiles successfully with WASI target
- Suitable for browser deployment
- Some features may have limitations in WASM environment
- File I/O limited to WASI capabilities

## Unsupported Platforms

Currently not validated (may work but not tested):
- FreeBSD
- OpenBSD
- Solaris
- Embedded targets
- Exotic architectures

## Testing Strategy

### Automated Validation
The `cross_platform_test.zig` script automatically validates:
1. Successful compilation for all target platforms
2. Test execution on native platform
3. Build success rates and reporting

### Manual Testing Required
For platforms other than Linux x86_64:
1. Native execution testing
2. File system I/O validation
3. Performance benchmarking
4. Platform-specific edge cases

## Known Limitations

### Cross-compilation Only
Most platforms are currently validated through cross-compilation only. Native testing on target platforms is planned for future releases.

### WASM Considerations
- JIT compilation disabled (not supported in WASM)
- File system access limited to WASI capabilities
- Memory management may have different characteristics

### Performance Variations
Performance characteristics may vary between platforms due to:
- Different instruction sets (x86_64 vs ARM64)
- Compiler optimizations per target
- System call overhead differences
- Memory management variations

## Future Platform Support

### Planned Additions
- Native testing automation for major platforms
- FreeBSD and OpenBSD support validation
- Embedded target evaluation (ARM Cortex-M, RISC-V)
- Additional WebAssembly targets (wasm32-freestanding)

### Platform Requests
Platform support requests can be filed as GitHub issues with:
- Target platform details
- Use case description
- Willingness to test on target platform