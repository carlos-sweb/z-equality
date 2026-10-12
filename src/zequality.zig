//! Equality and hashing helpers for the z-* micro-library ecosystem.
//!
//! Import this module with `const zequality = @import("zequality");`.
//! Scalars follow Strict Equality or SameValueZero numeric rules. Arrays and
//! slices compare by content, and ordinary pointers compare by address.
//! Structs and tagged unions delegate to public custom methods or std.meta.eql;
//! that fallback compares slice fields by pointer and does not normalize NaN.
//! Hashes are intended for in-memory containers, not cryptography or persistence.
//! See each function for the current limitations of the generic fallback.

const std = @import("std");

/// Strict Equality Comparison (ECMA262 ===): NaN !== NaN, +0 === -0.
/// `T` is the compile-time type of both operands. Scalars compare directly;
/// optionals, arrays and slices recurse, with early exit on a difference.
/// Structs/tagged unions use a public `eql(a: T, b: T) bool` when detected,
/// otherwise std.meta.eql. This structural extension is not JavaScript object
/// identity. Untagged unions need a custom method; unsupported types fail at
/// compile time. A custom comparator controls its own floating-point semantics.
/// Example: `strictEquals(i32, 5, 5)` returns true.
pub fn strictEquals(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .int, .bool, .comptime_int, .@"enum" => a == b,
        .float, .comptime_float => a == b,
        .pointer => |info| switch (info.size) {
            .slice => sliceEquals(info.child, a, b, false),
            .one, .many, .c => a == b,
        },
        .optional => optionalEquals(T, a, b, false),
        .array => |info| arrayEquals(info.child, T, a, b, false),
        .@"struct", .@"union" => containerEquals(T, a, b),
        else => @compileError("zequality: type '" ++ @typeName(T) ++
            "' does not support equality comparison. Provide a `pub fn eql(a: " ++
            @typeName(T) ++ ", b: " ++ @typeName(T) ++ ") bool` method on it."),
    };
}

/// SameValueZero (ECMA262): NaN equals NaN, +0 equals -0. Used by Array.includes(),
/// and by Map/Set key comparison.
/// `T` is the compile-time operand type. NaN handling recurses through optionals,
/// arrays and slices, but structs/unions retain strictEquals's custom/fallback
/// semantics. A plain struct containing NaN therefore does not equal itself.
/// Example: `sameValueZero(f64, std.math.nan(f64), std.math.nan(f64))` is true.
pub fn sameValueZero(comptime T: type, a: T, b: T) bool {
    return switch (@typeInfo(T)) {
        .float, .comptime_float => (a == b) or (std.math.isNan(a) and std.math.isNan(b)),
        .optional => optionalEquals(T, a, b, true),
        .array => |info| arrayEquals(info.child, T, a, b, true),
        .pointer => |info| switch (info.size) {
            .slice => sliceEquals(info.child, a, b, true),
            else => strictEquals(T, a, b),
        },
        else => strictEquals(T, a, b),
    };
}

fn sliceEquals(comptime E: type, a: []const E, b: []const E, comptime same_value_zero: bool) bool {
    if (a.len != b.len) return false;
    if (E == u8) return std.mem.eql(u8, a, b);
    for (a, b) |x, y| {
        const eq = if (same_value_zero) sameValueZero(E, x, y) else strictEquals(E, x, y);
        if (!eq) return false;
    }
    return true;
}

fn arrayEquals(comptime E: type, comptime T: type, a: T, b: T, comptime same_value_zero: bool) bool {
    for (a, b) |x, y| {
        const eq = if (same_value_zero) sameValueZero(E, x, y) else strictEquals(E, x, y);
        if (!eq) return false;
    }
    return true;
}

fn optionalEquals(comptime T: type, a: T, b: T, comptime same_value_zero: bool) bool {
    const Child = @typeInfo(T).optional.child;
    if (a == null or b == null) return a == null and b == null;
    return if (same_value_zero) sameValueZero(Child, a.?, b.?) else strictEquals(Child, a.?, b.?);
}

/// Duck-typing: if T (a struct or a tagged union — e.g. a JSValue-shaped
/// discriminated union) declares `pub fn eql(a: T, b: T) bool`, it is used.
/// Otherwise falls back to std.meta.eql field-by-field/tag-and-payload (note:
/// slice fields inside compare by pointer identity unless T provides its own eql).
fn containerEquals(comptime T: type, a: T, b: T) bool {
    if (comptime hasCustomEql(T)) {
        return T.eql(a, b);
    }
    return std.meta.eql(a, b);
}

fn isContainerType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => true,
        else => false,
    };
}

/// Returns whether `T` is a struct/union with a public function named `eql`
/// taking two parameters. Parameter types, return type and genericity are not
/// validated; true does not guarantee that `T.eql(a, b)` is callable.
/// Used at compile time by the equality and hashing dispatch.
pub fn hasCustomEql(comptime T: type) bool {
    if (comptime !isContainerType(T)) return false;
    if (!@hasDecl(T, "eql")) return false;
    const fn_info = @typeInfo(@TypeOf(@field(T, "eql")));
    return fn_info == .@"fn" and fn_info.@"fn".param_types.len == 2;
}

/// Returns whether `T` is a struct/union with a public function named `hash`
/// taking one parameter. Parameter types, return type and genericity are not
/// validated. The current hash dispatch uses this method only when a matching
/// custom eql is also present. Other types return false.
pub fn hasCustomHash(comptime T: type) bool {
    if (comptime !isContainerType(T)) return false;
    if (!@hasDecl(T, "hash")) return false;
    const fn_info = @typeInfo(@TypeOf(@field(T, "hash")));
    return fn_info == .@"fn" and fn_info.@"fn".param_types.len == 1;
}

/// Content hash consistent with sameValueZero: values equal under
/// sameValueZero MUST hash identically, since HashMap-style containers
/// require eql(a,b) => hash(a)==hash(b). Used by ZArray.unique()/groupBy(),
/// and by Map/Set key hashing, so that []const u8 and other slices hash by
/// content instead of pointer identity.
/// `T` is the compile-time type of `value`. Uses Wyhash with seed zero;
/// optional null has a fixed hash, and ordinary pointers hash their address.
/// Custom eql requires custom hash when hashing is instantiated. The container
/// fallback uses std.hash.autoHash, which rejects float fields and slice fields.
/// Use concrete numeric types: comptime_int/comptime_float hashing is unsupported.
/// The current f80 path includes integer storage padding; avoid f80 map keys
/// until that representation is fixed. Hash output is not a stable file format.
/// Example: `hash([]const u8, "hello")` hashes the string's content.
pub fn hash(comptime T: type, value: T) u64 {
    return switch (@typeInfo(T)) {
        .int, .bool, .comptime_int, .@"enum" => blk: {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, value);
            break :blk hasher.final();
        },
        .float, .comptime_float => hashFloat(T, value),
        .pointer => |info| switch (info.size) {
            .slice => hashSlice(info.child, value),
            .one, .many, .c => blk: {
                var hasher = std.hash.Wyhash.init(0);
                std.hash.autoHash(&hasher, @intFromPtr(value));
                break :blk hasher.final();
            },
        },
        .array => |info| hashSlice(info.child, &value),
        .optional => |info| if (value) |v| hash(info.child, v) else 0x9e3779b97f4a7c15,
        .@"struct", .@"union" => containerHash(T, value),
        else => @compileError("zequality: type '" ++ @typeName(T) ++
            "' does not support hashing. Provide a `pub fn hash(self: " ++
            @typeName(T) ++ ") u64` method on it."),
    };
}

fn hashFloat(comptime T: type, value: T) u64 {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    var bits: Bits = @bitCast(value);
    if (std.math.isNan(value)) {
        // SameValueZero treats every NaN payload as equal, so every NaN must
        // collapse to one canonical hash regardless of its bit pattern.
        bits = @bitCast(std.math.nan(T));
    } else if (value == 0) {
        // SameValueZero treats +0 and -0 as equal; canonicalize -0's bits to +0's.
        bits = @bitCast(@as(T, 0.0));
    }
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&bits));
    return hasher.final();
}

fn hashSlice(comptime E: type, value: []const E) u64 {
    if (E == u8) return std.hash.Wyhash.hash(0, value);
    var hasher = std.hash.Wyhash.init(0);
    for (value) |item| {
        const h = hash(E, item);
        hasher.update(std.mem.asBytes(&h));
    }
    return hasher.final();
}

/// Duck-typing mirrors containerEquals: if T declares `pub fn hash(self: T) u64`,
/// it is used. Otherwise falls back to std.hash.autoHash field-by-field
/// (consistent with containerEquals's std.meta.eql fallback, since both are
/// field-wise and agree with each other). If T provides a custom eql() but no
/// matching hash(), that's a correctness footgun for HashMap-backed uses
/// (equal-by-eql values could hash differently) — caught here at comptime.
fn containerHash(comptime T: type, value: T) u64 {
    if (comptime hasCustomEql(T)) {
        if (!comptime hasCustomHash(T)) {
            @compileError("zequality: type '" ++ @typeName(T) ++
                "' provides a custom eql() but no matching hash() — both are required " ++
                "together for HashMap-backed correctness (equal values must hash " ++
                "equally). Add `pub fn hash(self: " ++ @typeName(T) ++ ") u64`.");
        }
        return value.hash();
    }
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hasher, value);
    return hasher.final();
}

/// std.HashMap Context adapter (2-arg eql): SameValueZero equality +
/// content-based hash, for use where std.AutoHashMap's pointer-identity
/// hashing is wrong (e.g. T == []const u8).
/// `T` is the compile-time key type. The returned zero-field type exposes
/// `hash(self, key) u64` and `eql(self, a, b) bool` without allocating memory.
/// The adapter inherits all hash and sameValueZero limitations; user-defined
/// methods must satisfy eql(a, b) => hash(a) == hash(b).
/// Example type: `std.HashMap([]const u8, i32, HashContext([]const u8),
/// std.hash_map.default_max_load_percentage)`.
pub fn HashContext(comptime T: type) type {
    return struct {
        pub fn hash(self: @This(), key: T) u64 {
            _ = self;
            return @import("zequality.zig").hash(T, key);
        }
        pub fn eql(self: @This(), a: T, b: T) bool {
            _ = self;
            return sameValueZero(T, a, b);
        }
    };
}
