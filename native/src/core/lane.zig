//! A creep lane (CreepSpawner): its spawner's spot and the chain of lane nodes it walks.
//! Port of noh's CLane (src/hon_shared/c_lane.cpp) as CreepSpawner.next_waypoint has it.

/// CLane::GetNextWaypoint ignores waypoints closer than 100 noh units.
pub const waypoint_skip_distance: f32 = 100.0 / 48.0;

pub const Lane = struct {
    spawn: Vec3 = .{},
    points: []Vec3 = &.{},
    /// From each point toward the next; zero for the last.
    directions: []Vec3 = &.{},

    pub fn deinit(self: *Lane, gpa: Allocator) void {
        gpa.free(self.points);
        gpa.free(self.directions);
        self.* = .{};
    }

    pub fn set(self: *Lane, gpa: Allocator, spawn: Vec3, points: []const Vec3) !void {
        self.deinit(gpa);
        self.spawn = spawn;
        self.points = try gpa.dupe(Vec3, points);
        self.directions = try gpa.alloc(Vec3, points.len);
        for (self.directions, 0..) |*direction, i| {
            direction.* = if (i + 1 < points.len) points[i + 1].sub(points[i]).flat().normalized() else Vec3.zero;
        }
    }

    pub fn hasNodes(self: Lane) bool {
        return self.points.len > 0;
    }

    /// The closest waypoint that is ahead of `from` and not too close, searching onwards from
    /// the current one; the lane's end otherwise.
    pub fn next(self: Lane, from: Vec3, current: Vec3) Vec3 {
        if (self.points.len == 0) return self.spawn;
        var start: usize = 0;
        for (self.points, 0..) |point, i| {
            if (point.x == current.x and point.y == current.y and point.z == current.z) {
                start = i;
                break;
            }
        }
        var best = self.points[self.points.len - 1];
        var best_distance = std.math.inf(f32);
        for (self.points[start..], self.directions[start..]) |point, direction| {
            const offset = from.sub(point).flat();
            if (offset.dot(direction) >= 0) continue; // already past it
            const distance = offset.lengthSquared();
            if (distance < waypoint_skip_distance * waypoint_skip_distance) continue;
            if (distance < best_distance) {
                best_distance = distance;
                best = point;
            }
        }
        return best;
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("vec.zig").Vec3;

test "creeps head for the next node ahead" {
    const gpa = std.testing.allocator;
    var lane: Lane = .{};
    defer lane.deinit(gpa);
    try lane.set(gpa, .{ .z = 50 }, &.{ .{ .z = 0 }, .{ .z = -50 } });
    try std.testing.expectEqual(@as(f32, 0), lane.next(.{ .z = 50 }, Vec3.inf).z);
    // past the middle node: on to the end
    try std.testing.expectEqual(@as(f32, -50), lane.next(.{ .z = -1 }, Vec3.inf).z);
}
