const std = @import("std");
const testing = std.testing;
const equality = @import("zequality");

test "strictEquals ints and bools" {
    try testing.expect(equality.strictEquals(i32, 5, 5));
    try testing.expect(!equality.strictEquals(i32, 5, 6));
    try testing.expect(equality.strictEquals(bool, true, true));
    try testing.expect(!equality.strictEquals(bool, true, false));
}

test "strictEquals floats: NaN is never equal" {
    const nan = std.math.nan(f64);
    try testing.expect(!equality.strictEquals(f64, nan, nan));
    try testing.expect(equality.strictEquals(f64, 1.5, 1.5));
    try testing.expect(equality.strictEquals(f64, 0.0, -0.0));
}

test "sameValueZero floats: NaN equals NaN" {
    const nan = std.math.nan(f64);
    try testing.expect(equality.sameValueZero(f64, nan, nan));
    try testing.expect(equality.sameValueZero(f64, 0.0, -0.0));
}

test "strictEquals slices compare content, not pointer identity" {
    const a: []const u8 = "hello";
    var buf: [5]u8 = .{ 'h', 'e', 'l', 'l', 'o' };
    const b: []const u8 = buf[0..];

    try testing.expect(equality.strictEquals([]const u8, a, b));
    try testing.expect(!equality.strictEquals([]const u8, a, "world"));
}

test "sameValueZero slices compare content too" {
    const a: []const u8 = "abc";
    const b: []const u8 = "abc";
    try testing.expect(equality.sameValueZero([]const u8, a, b));
}

test "equality on optionals" {
    const a: ?i32 = null;
    const b: ?i32 = null;
    const c: ?i32 = 5;
    const d: ?i32 = 5;

    try testing.expect(equality.strictEquals(?i32, a, b));
    try testing.expect(equality.strictEquals(?i32, c, d));
    try testing.expect(!equality.strictEquals(?i32, a, c));
}

const EqPoint = struct {
    x: i32,
    y: i32,

    pub fn eql(a: EqPoint, b: EqPoint) bool {
        return a.x == b.x and a.y == b.y;
    }
};

test "structEquals uses custom eql when present" {
    try testing.expect(equality.hasCustomEql(EqPoint));
    try testing.expect(equality.strictEquals(EqPoint, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 2 }));
    try testing.expect(!equality.strictEquals(EqPoint, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 3 }));
}

const PlainPoint = struct { x: i32, y: i32 };

test "structEquals falls back to std.meta.eql without custom eql" {
    try testing.expect(!equality.hasCustomEql(PlainPoint));
    try testing.expect(equality.strictEquals(PlainPoint, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 2 }));
    try testing.expect(!equality.strictEquals(PlainPoint, .{ .x = 1, .y = 2 }, .{ .x = 9, .y = 9 }));
}

test "hash: values equal under sameValueZero hash identically" {
    // Different NaN bit patterns (different payloads) must collapse to one hash.
    const nan1 = std.math.nan(f64);
    const nan2: f64 = @bitCast(@as(u64, 0x7ff8000000000001));
    try testing.expect(std.math.isNan(nan2));
    try testing.expectEqual(equality.hash(f64, nan1), equality.hash(f64, nan2));

    // +0 and -0 must hash identically too.
    try testing.expectEqual(equality.hash(f64, 0.0), equality.hash(f64, -0.0));
}

test "hash: []const u8 hashes by content, not pointer identity" {
    const a: []const u8 = "hello";
    var buf: [5]u8 = .{ 'h', 'e', 'l', 'l', 'o' };
    const b: []const u8 = buf[0..];

    try testing.expectEqual(equality.hash([]const u8, a), equality.hash([]const u8, b));
    try testing.expect(equality.hash([]const u8, a) != equality.hash([]const u8, "world"));
}

const EqHashPoint = struct {
    x: i32,
    y: i32,

    pub fn eql(a: EqHashPoint, b: EqHashPoint) bool {
        return a.x == b.x and a.y == b.y;
    }

    pub fn hash(self: EqHashPoint) u64 {
        return @as(u64, @bitCast(@as(i64, self.x))) ^ @as(u64, @bitCast(@as(i64, self.y)));
    }
};

test "hash: struct with matching custom eql+hash is used" {
    try testing.expect(equality.hasCustomHash(EqHashPoint));
    const p1 = EqHashPoint{ .x = 1, .y = 2 };
    const p2 = EqHashPoint{ .x = 1, .y = 2 };
    try testing.expectEqual(equality.hash(EqHashPoint, p1), equality.hash(EqHashPoint, p2));
}

test "hash: plain struct without custom eql/hash falls back to field-wise hashing" {
    try testing.expect(!equality.hasCustomHash(PlainPoint));
    const p1 = PlainPoint{ .x = 1, .y = 2 };
    const p2 = PlainPoint{ .x = 1, .y = 2 };
    try testing.expectEqual(equality.hash(PlainPoint, p1), equality.hash(PlainPoint, p2));
}

test "HashContext works as a std.HashMap context" {
    var map = std.HashMap([]const u8, i32, equality.HashContext([]const u8), std.hash_map.default_max_load_percentage).init(testing.allocator);
    defer map.deinit();

    var buf: [5]u8 = .{ 'h', 'e', 'l', 'l', 'o' };
    const a: []const u8 = "hello";
    const b: []const u8 = buf[0..];

    try map.put(a, 1);
    try testing.expectEqual(@as(?i32, 1), map.get(b));
}

// Regression: discriminated unions (e.g. a JSValue-shaped tagged union used
// as a Map/Set key type) need the same duck-typed eql/hash support structs
// already have -- this is what z-map/z-set need for ZMap(JSValue, JSValue).
const EqUnion = union(enum) {
    a: i32,
    b: []const u8,

    pub fn eql(x: EqUnion, y: EqUnion) bool {
        return std.meta.eql(x, y);
    }
    pub fn hash(self: EqUnion) u64 {
        return switch (self) {
            .a => |v| @as(u64, @bitCast(@as(i64, v))),
            .b => |s| std.hash.Wyhash.hash(0, s),
        };
    }
};

test "union types support the same custom eql/hash duck-typing as structs" {
    try testing.expect(equality.hasCustomEql(EqUnion));
    try testing.expect(equality.hasCustomHash(EqUnion));

    const a1 = EqUnion{ .a = 1 };
    const a2 = EqUnion{ .a = 1 };
    const b1 = EqUnion{ .b = "x" };

    try testing.expect(equality.strictEquals(EqUnion, a1, a2));
    try testing.expect(!equality.strictEquals(EqUnion, a1, b1));
    try testing.expectEqual(equality.hash(EqUnion, a1), equality.hash(EqUnion, a2));
}
