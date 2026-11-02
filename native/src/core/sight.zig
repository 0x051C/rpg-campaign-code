//! The fog of war's visibility maps (noh CGameServer::UpdateVisibility): one byte per cell of a
//! padded grid per team, non-zero where the team sees. FogOfWar (scripts/rts/fog_of_war.gd) lays
//! the grid out and builds the occlusion map; the casting and every unit's sight bits are here.
//!
//! A cell blocks the sight of a unit whose eyes are below the cell's top (`heights`: terrain,
//! raised by props that block sight), so low ground can't see onto high ground or past walls.
//! noh rasterized sight with recursive shadowcasting (CRasterBuffer::CalcVisibilty2); here each
//! sight radius has a table of its cells, ring by ring outward, each pointing at the cell before
//! it on the line from the center: a cell is seen when that one is seen and doesn't block. Same
//! result (blockers are seen, what's behind them isn't), one flat loop per unit.
//!
//! The grid is padded by `pad` cells on every side, more than the longest sight radius, so a
//! cast never needs clipping.

pub const max_teams = 8;
pub const seen: u8 = 255;

/// The cells within one sight radius, ring by ring outward.
pub const Rays = struct {
    /// Each cell's offset from the center in the padded grid.
    offsets: []i32 = &.{},
    /// The ray index of the cell before it on the line from the center.
    parents: []u32 = &.{},

    fn deinit(self: *Rays, gpa: Allocator) void {
        gpa.free(self.offsets);
        gpa.free(self.parents);
    }
};

pub const Sight = struct {
    origin_x: f32 = 0,
    origin_z: f32 = 0,
    cell: f32 = 1,
    size_x: usize = 0,
    size_z: usize = 0,
    pad: usize = 0,
    width: usize = 0,
    /// Per team: the last finished map; empty for a team that never had one.
    maps: [max_teams][]u8 = @splat(&.{}),
    /// Per team: the next map, while it's cast.
    building: [max_teams][]u8 = @splat(&.{}),
    /// Per padded cell: the top of what is there (COcclusionMap); inf off the map.
    heights: []f32 = &.{},
    /// Per padded cell: the ground at its center, where eyes stand.
    ground: []f32 = &.{},
    /// Ray tables by radius in cells, built on first use.
    rays: std.ArrayList(Rays) = .empty,
    /// Scratch for a cast: seen and not blocking, per ray.
    open: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Sight, gpa: Allocator) void {
        for (&self.maps, &self.building) |*map, *next| {
            gpa.free(map.*);
            gpa.free(next.*);
        }
        gpa.free(self.heights);
        gpa.free(self.ground);
        for (self.rays.items) |*rays| rays.deinit(gpa);
        self.rays.deinit(gpa);
        self.open.deinit(gpa);
        self.* = .{};
    }

    /// `size` cells of `cell` meters from `origin` (world XZ), padded by `pad`. Drops the maps.
    pub fn setLayout(self: *Sight, gpa: Allocator, origin_x: f32, origin_z: f32, cell: f32, size_x: usize, size_z: usize, pad: usize) void {
        self.deinit(gpa);
        self.* = .{ .origin_x = origin_x, .origin_z = origin_z, .cell = cell, .size_x = size_x, .size_z = size_z, .pad = pad, .width = size_x + pad * 2 };
    }

    pub fn cellCount(self: Sight) usize {
        return self.width * (self.size_z + self.pad * 2);
    }

    /// The occlusion map and the ground, one value per padded cell each.
    pub fn setOcclusion(self: *Sight, gpa: Allocator, heights: []const f32, ground: []const f32) !void {
        if (heights.len != self.cellCount() or ground.len != self.cellCount()) return;
        gpa.free(self.heights);
        gpa.free(self.ground);
        self.heights = &.{};
        self.ground = &.{};
        self.heights = try gpa.dupe(f32, heights);
        self.ground = try gpa.dupe(f32, ground);
    }

    /// A team's finished map, set from outside (tests).
    pub fn setMap(self: *Sight, gpa: Allocator, team: usize, cells: []const u8) !void {
        if (team >= max_teams) return;
        gpa.free(self.maps[team]);
        self.maps[team] = &.{};
        self.maps[team] = try gpa.dupe(u8, cells);
    }

    /// The team gets a map (blank) if it has none; maps are kept once made.
    pub fn ensureTeam(self: *Sight, gpa: Allocator, team: usize) !void {
        if (team >= max_teams or self.building[team].len != 0) return;
        self.building[team] = try gpa.alloc(u8, self.cellCount());
        @memset(self.building[team], 0);
        if (self.maps[team].len != self.cellCount()) {
            gpa.free(self.maps[team]);
            self.maps[team] = &.{};
            self.maps[team] = try gpa.alloc(u8, self.cellCount());
            @memset(self.maps[team], 0);
        }
    }

    /// Clears the maps being built, before an update casts into them.
    pub fn startUpdate(self: *Sight) void {
        for (self.building) |map| @memset(map, 0);
    }

    /// The update is cast: it becomes what the teams see.
    pub fn publish(self: *Sight) void {
        for (&self.maps, &self.building) |*map, *next| {
            if (next.len == 0) continue;
            std.mem.swap([]u8, map, next);
        }
    }

    /// Marks in `team`'s map being built every cell seen from `point` by eyes at `eye`, out to
    /// `range` meters (cut short at the padding).
    pub fn look(self: *Sight, gpa: Allocator, team: usize, point: Vec3, eye: f32, range: f32) !void {
        if (team >= max_teams or self.heights.len == 0) return;
        const cells: usize = @intFromFloat(@max(@floor(range / self.cell), 0));
        const radius = @min(cells, self.pad -| 1);
        if (radius == 0) return;
        try self.ensureTeam(gpa, team);
        const rays = try self.raysFor(gpa, radius);
        self.cast(self.building[team], self.cellIndex(point), eye, rays);
    }

    /// The eye height of a unit standing at `point`, `above` its ground.
    pub fn eyeAt(self: Sight, point: Vec3, above: f32) f32 {
        if (self.ground.len == 0) return std.math.inf(f32);
        return self.ground[self.cellIndex(point)] + point.y + above;
    }

    fn cast(self: *Sight, map: []u8, center: usize, eye: f32, rays: Rays) void {
        const open = self.open.items[0..rays.parents.len];
        map[center] = seen;
        open[0] = 1; // a unit always sees out of its own cell
        const origin: isize = @intCast(center);
        for (rays.offsets[1..], rays.parents[1..], open[1..]) |offset, parent, *is_open| {
            if (open[parent] != 0) {
                const cell: usize = @intCast(origin + offset);
                map[cell] = seen; // a blocking cell is seen itself; it hides what lies behind it
                is_open.* = @intFromBool(self.heights[cell] <= eye);
            } else {
                is_open.* = 0;
            }
        }
    }

    /// FogOfWar._rays_for: the table of a sight radius, built on first use.
    pub fn raysFor(self: *Sight, gpa: Allocator, radius: usize) !Rays {
        while (self.rays.items.len <= radius) try self.rays.append(gpa, .{});
        const existing = self.rays.items[radius];
        if (existing.offsets.len != 0) return existing;

        const r: i32 = @intCast(radius);
        const side: usize = radius * 2 + 1;
        const index = try gpa.alloc(u32, side * side); // ray index of each cell of the square
        defer gpa.free(index);
        @memset(index, std.math.maxInt(u32));
        var offsets: std.ArrayList(i32) = .empty;
        errdefer offsets.deinit(gpa);
        var parents: std.ArrayList(u32) = .empty;
        errdefer parents.deinit(gpa);
        const limit = r * r + r; // rounder than r², like noh's midpoint circles
        const width: i32 = @intCast(self.width);
        var ring: i32 = 0;
        while (ring <= r) : (ring += 1) {
            var cells: RingCells = .{ .ring = ring };
            while (cells.next()) |cell| {
                if (cell[0] * cell[0] + cell[1] * cell[1] > limit) continue;
                var parent: u32 = 0;
                if (ring > 0) {
                    // The previous step on the line from the center: one ring further in
                    const shrink = @as(f32, @floatFromInt(ring - 1)) / @as(f32, @floatFromInt(ring));
                    const px: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(cell[0])) * shrink));
                    const pz: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(cell[1])) * shrink));
                    const found = index[squareIndex(px, pz, r, side)];
                    parent = if (found == std.math.maxInt(u32)) 0 else found;
                }
                index[squareIndex(cell[0], cell[1], r, side)] = @intCast(offsets.items.len);
                try offsets.append(gpa, cell[1] * width + cell[0]);
                try parents.append(gpa, parent);
            }
        }
        if (self.open.items.len < offsets.items.len) try self.open.resize(gpa, offsets.items.len);
        const rays: Rays = .{ .offsets = try offsets.toOwnedSlice(gpa), .parents = try parents.toOwnedSlice(gpa) };
        self.rays.items[radius] = rays;
        return rays;
    }

    /// FogOfWar._cell_index: the padded cell under `point`, clamped to the map.
    pub fn cellIndex(self: Sight, point: Vec3) usize {
        const x: i64 = @intFromFloat(@floor((point.x - self.origin_x) / self.cell));
        const z: i64 = @intFromFloat(@floor((point.z - self.origin_z) / self.cell));
        const cx: usize = @intCast(std.math.clamp(x, 0, @as(i64, @intCast(@max(self.size_x, 1) - 1))));
        const cz: usize = @intCast(std.math.clamp(z, 0, @as(i64, @intCast(@max(self.size_z, 1) - 1))));
        return (cz + self.pad) * self.width + cx + self.pad;
    }

    /// noh VIS_SIGHTED: its own team, the teams whose maps cover its cell, and the teams it
    /// attacked since `since`.
    pub fn bitsFor(self: Sight, team: u8, stealthed: bool, position: Vec3, aggressions: [8]f64, since: f64) i32 {
        var bits: i32 = @as(i32, 1) << @intCast(team);
        if (stealthed) return bits; // noh: stealthed units show only to their own team
        const cell = self.cellIndex(position);
        for (self.maps, 0..) |map, other| {
            if (map.len == 0) continue;
            if ((cell < map.len and map[cell] != 0) or aggressions[other] > since) bits |= @as(i32, 1) << @intCast(other);
        }
        return bits;
    }
};

fn squareIndex(x: i32, z: i32, r: i32, side: usize) usize {
    return @as(usize, @intCast(z + r)) * side + @as(usize, @intCast(x + r));
}

/// The cells of one ring of the square around the center, in FogOfWar._ring's order.
const RingCells = struct {
    ring: i32,
    step: i32 = 0,

    fn next(self: *RingCells) ?[2]i32 {
        const r = self.ring;
        if (r == 0) {
            if (self.step > 0) return null;
            self.step = 1;
            return .{ 0, 0 };
        }
        const across = 2 * r + 1; // x from -r to r: top and bottom rows
        const rows_ = 2 * r - 1; // y from -r + 1 to r - 1: left and right columns
        defer self.step += 1;
        if (self.step < across * 2) {
            const x = -r + @divTrunc(self.step, 2);
            return if (@mod(self.step, 2) == 0) .{ x, -r } else .{ x, r };
        }
        const s = self.step - across * 2;
        if (s < rows_ * 2) {
            const y = -r + 1 + @divTrunc(s, 2);
            return if (@mod(s, 2) == 0) .{ -r, y } else .{ r, y };
        }
        return null;
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const Vec3 = @import("vec.zig").Vec3;

test "sight stops at a wall, and the wall is seen" {
    const gpa = std.testing.allocator;
    var sight: Sight = .{};
    defer sight.deinit(gpa);
    sight.setLayout(gpa, 0, 0, 1, 20, 20, 8);
    const n = sight.cellCount();
    const heights = try gpa.alloc(f32, n);
    defer gpa.free(heights);
    const ground = try gpa.alloc(f32, n);
    defer gpa.free(ground);
    @memset(heights, 0);
    @memset(ground, 0);
    // A wall along x = 10, 5 m high
    for (0..20) |z| heights[sight.cellIndex(.{ .x = 10.5, .z = @floatFromInt(z) })] = 5;
    try sight.setOcclusion(gpa, heights, ground);

    sight.startUpdate();
    try sight.look(gpa, 1, .{ .x = 5.5, .z = 10.5 }, sight.eyeAt(.{ .x = 5.5, .z = 10.5 }, 1.3), 7);
    sight.publish();
    const map = sight.maps[1];
    try std.testing.expect(map[sight.cellIndex(.{ .x = 8.5, .z = 10.5 })] != 0); // in front of the wall
    try std.testing.expect(map[sight.cellIndex(.{ .x = 10.5, .z = 10.5 })] != 0); // the wall itself
    try std.testing.expect(map[sight.cellIndex(.{ .x = 11.5, .z = 10.5 })] == 0); // behind it
    try std.testing.expect(map[sight.cellIndex(.{ .x = 5.5, .z = 19.5 })] == 0); // out of range
    // Clear vision sees over it
    sight.startUpdate();
    try sight.look(gpa, 1, .{ .x = 5.5, .z = 10.5 }, std.math.inf(f32), 7);
    sight.publish();
    try std.testing.expect(sight.maps[1][sight.cellIndex(.{ .x = 11.5, .z = 10.5 })] != 0);
    // Every ray of a table points further in
    const rays = try sight.raysFor(gpa, 7);
    for (rays.parents, 0..) |parent, i| try std.testing.expect(i == 0 or parent < i);
}
