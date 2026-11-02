//! A copy of the map's WalkGrid (scripts/rts/walk_grid.gd): its navigation mesh as a grid of
//! bytes, CELL meters square, 1 where a cell's middle lies in a polygon.

pub const WalkGrid = struct {
    origin_x: f32 = 0,
    origin_z: f32 = 0,
    width: usize = 0,
    depth: usize = 0,
    cell: f32 = 0.5,
    cells: []u8 = &.{},

    pub fn deinit(self: *WalkGrid, gpa: Allocator) void {
        gpa.free(self.cells);
        self.* = .{};
    }

    pub fn set(self: *WalkGrid, gpa: Allocator, origin_x: f32, origin_z: f32, width: usize, depth: usize, cell: f32, cells: []const u8) !void {
        gpa.free(self.cells);
        self.* = .{ .origin_x = origin_x, .origin_z = origin_z, .width = width, .depth = depth, .cell = cell };
        self.cells = try gpa.dupe(u8, cells);
    }

    pub fn isEmpty(self: WalkGrid) bool {
        return self.cells.len == 0;
    }

    pub fn isWalkable(self: WalkGrid, at: Vec3) bool {
        const column = @floor((at.x - self.origin_x) / self.cell);
        const row = @floor((at.z - self.origin_z) / self.cell);
        if (column < 0 or row < 0) return false;
        const c: usize = @intFromFloat(column);
        const r: usize = @intFromFloat(row);
        return c < self.width and r < self.depth and self.cells[r * self.width + c] == 1;
    }

    /// Where a unit at `from` heading for `to` (one tick's move) ends up: `to` on walkable ground,
    /// else sliding along the wall on one axis; null when neither works (ask the NavigationServer).
    pub fn step(self: WalkGrid, from: Vec3, to: Vec3) ?Vec3 {
        if (self.isWalkable(to)) return to;
        const along_x: Vec3 = .{ .x = to.x, .y = to.y, .z = from.z };
        if (self.isWalkable(along_x)) return along_x;
        const along_z: Vec3 = .{ .x = from.x, .y = to.y, .z = to.z };
        if (self.isWalkable(along_z)) return along_z;
        return null;
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("vec.zig").Vec3;

test "steps slide along walls" {
    const gpa = std.testing.allocator;
    var grid: WalkGrid = .{};
    defer grid.deinit(gpa);
    // 2x2 cells of 1 m from the origin; the cell at x 1, z 1 is a wall
    try grid.set(gpa, 0, 0, 2, 2, 1, &.{ 1, 1, 1, 0 });
    try std.testing.expect(grid.isWalkable(.{ .x = 0.5, .z = 0.5 }));
    try std.testing.expect(!grid.isWalkable(.{ .x = 1.5, .z = 1.5 }));
    const slid = grid.step(.{ .x = 0.5, .z = 1.5 }, .{ .x = 1.5, .z = 1.6 }).?;
    try std.testing.expectEqual(@as(f32, 0.5), slid.x);
    try std.testing.expectEqual(@as(?Vec3, null), grid.step(.{ .x = 1.5, .z = 1.5 }, .{ .x = 2.5, .z = 2.5 }));
}
