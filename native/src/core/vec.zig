//! Vectors as Godot lays them out (three f32), so whole columns copy straight into packed arrays.

pub const Vec3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero: Vec3 = .{};
    /// "Not set": what GDScript's Vector3.INF stands for.
    pub const inf: Vec3 = .{ .x = std.math.inf(f32), .y = std.math.inf(f32), .z = std.math.inf(f32) };

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    pub fn lengthSquared(a: Vec3) f32 {
        return a.x * a.x + a.y * a.y + a.z * a.z;
    }
    pub fn distance(a: Vec3, b: Vec3) f32 {
        return @sqrt(a.sub(b).lengthSquared());
    }
    /// Distance seen from above (gameplay is on the XZ plane).
    pub fn flatDistance(a: Vec3, b: Vec3) f32 {
        const dx = a.x - b.x;
        const dz = a.z - b.z;
        return @sqrt(dx * dx + dz * dz);
    }
    pub fn flat(a: Vec3) Vec3 {
        return .{ .x = a.x, .y = 0, .z = a.z };
    }
    pub fn normalized(a: Vec3) Vec3 {
        const length = @sqrt(a.lengthSquared());
        return if (length > 0) a.scale(1 / length) else zero;
    }
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn isInf(a: Vec3) bool {
        return std.math.isInf(a.x);
    }
};

/// Godot's rotate_toward: `from` turned toward `to` by at most `delta`, the short way round.
pub fn rotateToward(from: f32, to: f32, delta: f32) f32 {
    const difference = angleDifference(from, to);
    const size = @abs(difference);
    const step = std.math.clamp(delta, size - std.math.pi, size);
    return from + (if (difference >= 0) step else -step);
}

/// Godot's angle_difference: the signed shortest turn from `from` to `to`.
pub fn angleDifference(from: f32, to: f32) f32 {
    const tau = 2 * std.math.pi;
    const difference = @mod(to - from, tau);
    return @mod(2 * difference, tau) - difference;
}

const std = @import("std");

test "turning goes the short way and stops on target" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), rotateToward(0, 1, 0.1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), rotateToward(0, 1, 2), 1e-6);
    // From just under a full turn toward 0.1: forward across the wrap, not back
    const turned = rotateToward(6.2, 0.1, 0.05);
    try std.testing.expect(turned > 6.2);
}
