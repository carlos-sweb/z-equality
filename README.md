# Z-Equality

[![Zig Version](https://img.shields.io/badge/zig-0.17-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Shared ECMA-262 **Strict Equality Comparison** / **SameValueZero** / content-hashing helpers for the [z-*](https://github.com/carlos-sweb) micro-library ecosystem, extracted from `z-array` so `z-array`, `z-value`, `z-map`, and `z-set` all share one implementation instead of four copies of the same algorithm.

## API

- `strictEquals(comptime T, a: T, b: T) bool` — ECMA-262 `===`: `NaN !== NaN`, `+0 === -0`.
- `sameValueZero(comptime T, a: T, b: T) bool` — `NaN` equals `NaN`, `+0` equals `-0`. Used by `Array.prototype.includes()`, and by `Map`/`Set` key/value comparison.
- `hash(comptime T, value: T) u64` — content hash consistent with `sameValueZero` (equal values always hash equally, including the NaN/±0 cases above).
- `HashContext(comptime T)` — `std.HashMap`-compatible context (2-arg `eql`) wrapping `sameValueZero`/`hash`.
- `hasCustomEql(comptime T) bool` / `hasCustomHash(comptime T) bool` — duck-typing checks for a struct's own `eql`/`hash` methods.

Equality supports integers, booleans, floats, enums, optionals, arrays, slices and ordinary pointers. Structs and tagged unions use public custom methods or `std.meta.eql`; the fallback compares slice fields by pointer identity and does not apply SameValueZero to nested NaNs. This is a Zig structural extension of the numeric rules, not JavaScript object identity.

Hashing supports concrete scalar types and supported arrays/slices/optionals. Structs and tagged unions containing float or slice fields need a custom `eql`/`hash` pair because the generic `std.hash.autoHash` fallback rejects those fields. A custom `eql` without `hash` fails at compile time **when hashing is used**. A lone custom `hash` is currently ignored. Avoid `f80` keys until storage-padding handling is corrected. Hashes are for in-memory containers, not cryptography or persistent identifiers.

## Installation

Requires Zig **0.17.0**. From your Zig project's directory, add release **0.1.0**:

```bash
zig fetch --save=zequality https://github.com/carlos-sweb/z-equality/archive/refs/tags/v0.1.0.tar.gz
```

Zig downloads the package, computes its content hash and records it in your `build.zig.zon`. Commit that manifest to pin the dependency. In your `build.zig`, add the module to the executable or library that imports it:

```zig
const zequality_dep = b.dependency("zequality", .{});
exe.root_module.addImport("zequality", zequality_dep.module("zequality"));
```

Here `exe` is your existing `b.addExecutable(...)` result. Use the same `root_module.addImport` call for library or test artifacts.

## Usage

```zig
const std = @import("std");
const zequality = @import("zequality");

pub fn main() void {
    std.debug.assert(!zequality.strictEquals(f64, std.math.nan(f64), std.math.nan(f64)));
    std.debug.assert(zequality.sameValueZero(f64, std.math.nan(f64), std.math.nan(f64)));
    std.debug.assert(zequality.strictEquals([]const u8, "hello", "hello"));
}
```

For content-based string keys:

```zig
var map = std.HashMap([]const u8, i32, zequality.HashContext([]const u8), std.hash_map.default_max_load_percentage).init(allocator);
defer map.deinit();
try map.put("hello", 42);
```

`allocator` is your application's allocator. The map stores slices without copying their bytes, so keep key storage alive and unchanged while it is in the map.

## API documentation

[Browse the generated Zig API documentation](https://carlos-sweb.github.io/z-equality/).

Generate the same documentation locally with:

```bash
zig build docs
python3 -m http.server 8000 --directory zig-out/docs
```

Open `http://localhost:8000/`. The `Zig API documentation` GitHub Actions workflow runs tests, generates the native Zig docs and publishes them to GitHub Pages on each push to `master`.

## Testing

Requires Zig **0.17.0** or later. The development toolchain is pinned to 0.17.0 in `mise.toml`.

```bash
zig build test
```

The migration follows the [Zig 0.17.0 release notes](https://ziglang.org/download/0.17.0/release-notes.html): function reflection uses `param_types`, and float hashing uses `@Int` to construct its bit representation.

## License

MIT
