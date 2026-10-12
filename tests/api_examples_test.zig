const std = @import("std");
const zequality = @import("zequality");

test "documented scalar and string examples" {
    try std.testing.expect(zequality.strictEquals(i32, 5, 5));
    try std.testing.expect(!zequality.strictEquals(f64, std.math.nan(f64), std.math.nan(f64)));
    try std.testing.expect(zequality.sameValueZero(f64, std.math.nan(f64), std.math.nan(f64)));
    try std.testing.expect(zequality.strictEquals([]const u8, "hello", "hello"));
    try std.testing.expectEqual(zequality.hash([]const u8, "hello"), zequality.hash([]const u8, "hello"));
}

test "documented HashContext and custom methods examples" {
    var map = std.HashMap([]const u8, i32, zequality.HashContext([]const u8), std.hash_map.default_max_load_percentage).init(std.testing.allocator);
    defer map.deinit();
    try map.put("hello", 42);
    try std.testing.expectEqual(@as(?i32, 42), map.get("hello"));

    const Point = struct {
        x: i32,
        pub fn eql(a: @This(), b: @This()) bool {
            return a.x == b.x;
        }
        pub fn hash(self: @This()) u64 {
            return zequality.hash(i32, self.x);
        }
    };
    try std.testing.expect(zequality.hasCustomEql(Point));
    try std.testing.expect(zequality.hasCustomHash(Point));
    try std.testing.expect(zequality.sameValueZero(Point, .{ .x = 7 }, .{ .x = 7 }));
    try std.testing.expectEqual(zequality.hash(Point, .{ .x = 7 }), zequality.hash(Point, .{ .x = 7 }));
}
