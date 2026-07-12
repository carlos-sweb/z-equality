const std = @import("std");

/// Strict Equality Comparison (ECMA262 ===): NaN !== NaN, +0 === -0.
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
        .@"struct" => structEquals(T, a, b),
        else => @compileError("zequality: type '" ++ @typeName(T) ++
            "' does not support equality comparison. Provide a `pub fn eql(a: " ++
            @typeName(T) ++ ", b: " ++ @typeName(T) ++ ") bool` method on it."),
    };
}

/// SameValueZero (ECMA262): NaN equals NaN, +0 equals -0. Used by Array.includes(),
/// and by Map/Set key comparison.
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

/// Duck-typing: if T declares `pub fn eql(a: T, b: T) bool`, it is used.
/// Otherwise falls back to std.meta.eql field-by-field (note: slice fields inside
/// the struct compare by pointer identity unless the struct provides its own eql).
fn structEquals(comptime T: type, a: T, b: T) bool {
    if (comptime hasCustomEql(T)) {
        return T.eql(a, b);
    }
    return std.meta.eql(a, b);
}

pub fn hasCustomEql(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "eql")) return false;
    const fn_info = @typeInfo(@TypeOf(@field(T, "eql")));
    return fn_info == .@"fn" and fn_info.@"fn".params.len == 2;
}

pub fn hasCustomHash(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "hash")) return false;
    const fn_info = @typeInfo(@TypeOf(@field(T, "hash")));
    return fn_info == .@"fn" and fn_info.@"fn".params.len == 1;
}

/// Content hash consistent with sameValueZero: values equal under
/// sameValueZero MUST hash identically, since HashMap-style containers
/// require eql(a,b) => hash(a)==hash(b). Used by ZArray.unique()/groupBy(),
/// and by Map/Set key hashing, so that []const u8 and other slices hash by
/// content instead of pointer identity.
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
        .@"struct" => hashStruct(T, value),
        else => @compileError("zequality: type '" ++ @typeName(T) ++
            "' does not support hashing. Provide a `pub fn hash(self: " ++
            @typeName(T) ++ ") u64` method on it."),
    };
}

fn hashFloat(comptime T: type, value: T) u64 {
    const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
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

/// Duck-typing mirrors structEquals: if T declares `pub fn hash(self: T) u64`,
/// it is used. Otherwise falls back to std.hash.autoHash field-by-field
/// (consistent with structEquals's std.meta.eql fallback, since both are
/// field-wise and agree with each other). If T provides a custom eql() but no
/// matching hash(), that's a correctness footgun for HashMap-backed uses
/// (equal-by-eql values could hash differently) — caught here at comptime.
fn hashStruct(comptime T: type, value: T) u64 {
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
