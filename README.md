# Z-Equality

[![Zig Version](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Shared ECMA-262 **Strict Equality Comparison** / **SameValueZero** / content-hashing helpers for the [z-*](https://github.com/carlos-sweb) micro-library ecosystem, extracted from `z-array` so `z-array`, `z-value`, `z-map`, and `z-set` all share one implementation instead of four copies of the same algorithm.

## API

- `strictEquals(comptime T, a: T, b: T) bool` — ECMA-262 `===`: `NaN !== NaN`, `+0 === -0`.
- `sameValueZero(comptime T, a: T, b: T) bool` — `NaN` equals `NaN`, `+0` equals `-0`. Used by `Array.prototype.includes()`, and by `Map`/`Set` key/value comparison.
- `hash(comptime T, value: T) u64` — content hash consistent with `sameValueZero` (equal values always hash equally, including the NaN/±0 cases above).
- `HashContext(comptime T)` — `std.HashMap`-compatible context (2-arg `eql`) wrapping `sameValueZero`/`hash`.
- `hasCustomEql(comptime T) bool` / `hasCustomHash(comptime T) bool` — duck-typing checks for a struct's own `eql`/`hash` methods.

Supports `int`/`bool`/`float`/`enum`/`optional`/`array`/slice (`[]const u8` and others, by content)/`struct` (via a custom `eql`/`hash` pair, or field-wise fallback). Structs with a custom `eql()` but no matching `hash()` are a compile error — required together for `HashMap`-backed correctness.

## Usage

```zig
const zequality = @import("zequality");

zequality.strictEquals(f64, std.math.nan(f64), std.math.nan(f64)); // false
zequality.sameValueZero(f64, std.math.nan(f64), std.math.nan(f64)); // true
```

## Testing

```bash
zig build test
```

## License

MIT
