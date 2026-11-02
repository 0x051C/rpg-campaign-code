//! The unit registry's data and its creep behavior: one store per kind (heroes, NPCs, summons),
//! each a structure of arrays, with the kind in every handle's shape. GDScript's UnitRegistry
//! keeps the rules that need the game's resources (damage, spells, drops, nodes) and calls in
//! here for the data and the loops over it.
//!
//! step() is one tick of the game's clock (Simulation):
//!   collect(): the engine's answers to last tick's questions, worked out meanwhile on other
//!     threads: NPCs stuck at a corner go to the closest walkable point, and new paths replace the
//!     ones their NPCs were following.
//!   tick(): flash timers, dying timers (`buried`), NPCs moving along their avoidance velocity on
//!     the walk grid (`corners` where the grid can't tell), and thinking: target, swing (`landed`
//!     swings), attack-move; NPCs that want a new path ask for one (`path_requests`).
//!   resolve(): starts up to `path_threads` threads asking the Navigator (the NavigationServer,
//!     in the extension) for the corners' closest walkable points and the paths. They run while
//!     the rest of the frame does (drawing, animation, GDScript) and are collected next tick;
//!     until then an NPC stays at its corner, or follows the path it had.
//!   finish(): NPCs follow their paths (the velocity they ask the avoidance for) and turn.
//! Then GDScript applies the events: landed swings deal damage, buried NPCs become corpses.
//! Without a Navigator (the tests) the requests stay in `path_requests` for the caller to answer
//! (setPath).
//!
//! While questions are in flight the threads only read them and write their own answers;
//! whatever else touches paths (startNpc, release, clear, load) collects first.
//!
//! Every tick starts by keeping where each NPC was (`look.previous`), so the frames drawn until
//! the next tick can place it in between (displayPosition).
//!
//! The behavior follows noh (ICreepEntity::ServerFrameThink, CBAttackMove, IUnitEntity::
//! GetThreatLevel, AggroCreeps) as scripts/rts/unit_registry.gd had it in GDScript.

pub const Life = enum(u8) { free = 0, alive = 1, dying = 2, dead = 3 }; // UnitRegistry.Life

pub const neutral_team: u8 = 0;
pub const creature_team: u8 = 3;
pub const max_teams = @import("sight.zig").max_teams;
const noh_units: f32 = 48.0;
pub const behavior_update_time: f32 = 0.5; // noh BEHAVIOR_UPDATE_MS
pub const leash_factor: f32 = 1.25; // a target this far beyond aggro range is dropped
pub const repath_time: f32 = 1.0;
pub const repath_distance: f32 = 0.75;
pub const path_point_reached: f32 = 0.6;
pub const home_reached: f32 = 1.0; // a camp creature this close to its spot stands still
pub const camp_aggro_time: f64 = 4.0;
pub const camp_leash: f32 = 1000.0 / noh_units;
pub const attack_aggro_range: f32 = 500.0 / noh_units; // g_heroAttackAggroRange
pub const attack_aggro_time: f64 = 2.0; // g_heroAttackAggroTime
pub const threat_creep: f32 = 2.0;
pub const threat_player_unit: f32 = 1.0;
/// A summon (Brook) comes before the heroes: it holds the enemies off its master instead of them turning back to her.
pub const threat_summon: f32 = 1.5;
pub const threat_current_target: f32 = 0.5;

pub const Aura = enum(u8) { armor = 0, ranged_damage_percent = 1, mana_regen = 2 }; // AuraAbility.Stat

pub fn RowOf(comptime kind: Kind) type {
    return switch (kind) {
        .hero => rows.HeroRow,
        .npc => rows.NpcRow,
        .summon => rows.SummonRow,
    };
}

/// Where a handle's row is now.
pub const Where = struct { kind: Kind, list: List, row: u32 };

/// What only the engine knows about walkable ground (the extension asks the NavigationServer).
/// `path` is called from several threads at once.
pub const Navigator = struct {
    context: *anyopaque,
    closestPoint: *const fn (context: *anyopaque, point: Vec3) Vec3,
    /// Replaces `out` with a path from `from` to `to`; empty when there's none.
    path: *const fn (context: *anyopaque, from: Vec3, to: Vec3, gpa: Allocator, out: *std.ArrayList(Vec3)) void,
};

/// Questions for the engine being answered on other threads, between one tick and the next.
pub const Flight = struct {
    corners: std.ArrayList(i64) = .empty,
    corner_points: std.ArrayList(Vec3) = .empty,
    /// The closest walkable point to each corner point.
    closest: std.ArrayList(Vec3) = .empty,
    next_corner: std.atomic.Value(usize) = .init(0),
    requests: std.ArrayList(i64) = .empty,
    froms: std.ArrayList(Vec3) = .empty,
    goals: std.ArrayList(Vec3) = .empty,
    /// One path per request, by request.
    answers: std.ArrayList(std.ArrayList(Vec3)) = .empty,
    /// The next request a thread takes: each takes the next one free until none are left.
    next: std.atomic.Value(usize) = .init(0),
    workers: [16]?std.Thread = @splat(null),
    nav: ?Navigator = null,
    gpa: ?Allocator = null,
    busy: bool = false,

    fn work(self: *Flight) void {
        const nav = self.nav.?;
        while (true) {
            const i = self.next_corner.fetchAdd(1, .monotonic);
            if (i >= self.corners.items.len) break;
            self.closest.items[i] = nav.closestPoint(nav.context, self.corner_points.items[i]);
        }
        while (true) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.requests.items.len) return;
            nav.path(nav.context, self.froms.items[i], self.goals.items[i], self.gpa.?, &self.answers.items[i]);
        }
    }

    fn deinit(self: *Flight, gpa: Allocator) void {
        self.corners.deinit(gpa);
        self.corner_points.deinit(gpa);
        self.closest.deinit(gpa);
        self.requests.deinit(gpa);
        self.froms.deinit(gpa);
        self.goals.deinit(gpa);
        for (self.answers.items) |*answer| answer.deinit(gpa);
        self.answers.deinit(gpa);
    }
};

pub const Units = struct {
    gpa: Allocator,
    heroes: Store(rows.HeroRow),
    npcs: Store(rows.NpcRow),
    summons: Store(rows.SummonRow),
    defs: std.ArrayList(Def) = .empty,
    lanes: std.ArrayList(Lane) = .empty,
    /// NPC paths, by handle index (variable length, so outside the rows).
    paths: [handle.per_kind]std.ArrayList(Vec3) = @splat(.empty),
    grid: WalkGrid = .{},
    sight: Sight = .{},
    clock: f64 = 0,
    nav: ?Navigator = null,
    /// Path requests are answered on up to this many threads (the NavigationServer's default
    /// navigation/pathfinding/max_threads is 4).
    path_threads: usize = 4,
    flight: Flight = .{},

    // What the last tick left for GDScript
    buried: std.ArrayList(i64) = .empty,
    corners: std.ArrayList(i64) = .empty,
    corner_points: std.ArrayList(Vec3) = .empty,
    landed_sources: std.ArrayList(i64) = .empty,
    landed_targets: std.ArrayList(i64) = .empty,
    path_requests: std.ArrayList(i64) = .empty,
    path_froms: std.ArrayList(Vec3) = .empty,
    path_goals: std.ArrayList(Vec3) = .empty,

    pub fn init(gpa: Allocator) Units {
        return .{ .gpa = gpa, .heroes = .init(), .npcs = .init(), .summons = .init() };
    }

    pub fn deinit(self: *Units) void {
        self.collect();
        const gpa = self.gpa;
        self.heroes.deinit(gpa);
        self.npcs.deinit(gpa);
        self.summons.deinit(gpa);
        self.defs.deinit(gpa);
        for (self.lanes.items) |*lane| lane.deinit(gpa);
        self.lanes.deinit(gpa);
        for (&self.paths) |*path| path.deinit(gpa);
        self.grid.deinit(gpa);
        self.sight.deinit(gpa);
        inline for (.{ &self.buried, &self.corners, &self.landed_sources, &self.landed_targets, &self.path_requests }) |list| list.deinit(gpa);
        inline for (.{ &self.corner_points, &self.path_froms, &self.path_goals }) |list| list.deinit(gpa);
        self.flight.deinit(gpa);
    }

    pub fn storeOf(self: *Units, comptime kind: Kind) *Store(RowOf(kind)) {
        return switch (kind) {
            .hero => &self.heroes,
            .npc => &self.npcs,
            .summon => &self.summons,
        };
    }

    // --- Handles ---------------------------------------------------------------------------

    pub fn locate(self: *Units, h: i64) ?Where {
        const kind = handle.kindOf(h) orelse return null;
        switch (kind) {
            inline else => |k| {
                const slot = self.storeOf(k).find(h) orelse return null;
                return .{ .kind = k, .list = slot.list, .row = slot.row };
            },
        }
    }

    pub fn isAlive(self: *Units, h: i64) bool {
        const where = self.locate(h) orelse return false;
        return where.list == .alive;
    }

    pub fn lifeOf(self: *Units, h: i64) Life {
        const where = self.locate(h) orelse return .free;
        if (where.list == .alive) return .alive;
        return if (where.kind == .npc) .dying else .dead;
    }

    /// A body field of any unit, by handle; null when the handle doesn't resolve.
    pub fn body(self: *Units, h: i64, comptime field: []const u8) ?*@FieldType(rows.Body, field) {
        const where = self.locate(h) orelse return null;
        return self.bodyAt(where, field);
    }

    pub fn bodyAt(self: *Units, where: Where, comptime field: []const u8) *@FieldType(rows.Body, field) {
        switch (where.kind) {
            inline else => |k| {
                const S = Store(RowOf(k));
                return &self.storeOf(k).rows(where.list).items(@field(S.Field, field))[where.row];
            },
        }
    }

    /// An NPC-only field (its brain); null for other kinds and for handles that don't resolve.
    pub fn brain(self: *Units, h: i64, comptime field: []const u8) ?*@FieldType(rows.NpcRow, field) {
        const where = self.locate(h) orelse return null;
        if (where.kind != .npc) return null;
        return &self.npcs.rows(where.list).items(@field(Store(rows.NpcRow).Field, field))[where.row];
    }

    fn handleOf(self: *Units, comptime kind: Kind, index: u16) i64 {
        return handle.make(kind, index, self.storeOf(kind).slots[index].generation);
    }

    // --- Units coming and going ------------------------------------------------------------

    /// A new living unit of `kind` with this body; handle.none when its pool is full.
    pub fn create(self: *Units, kind: Kind, start: rows.Body) !i64 {
        switch (kind) {
            inline else => |k| {
                var row: RowOf(k) = .{};
                inline for (@typeInfo(rows.Body).@"struct".field_names) |name| @field(row, name) = @field(start, name);
                row.look.previous = start.position;
                row.look.previous_yaw = start.yaw;
                return (try self.storeOf(k).create(self.gpa, k, row)) orelse handle.none;
            },
        }
    }

    /// Gives an NPC its lane (-1: stands still) and its spot to come back to.
    pub fn startNpc(self: *Units, h: i64, lane: i16, home: Vec3, scan_offset: f32) void {
        self.collect();
        const where = self.locate(h) orelse return;
        if (where.kind != .npc) return;
        const index = handle.indexOf(h);
        var row = self.npcs.rows(where.list).get(where.row);
        const fresh: rows.NpcRow = .{};
        inline for (@typeInfo(rows.Brain).@"struct".field_names) |name| @field(row, name) = @field(fresh, name);
        row.route = .{ .lane = lane, .home = home };
        row.timers.scan = scan_offset;
        self.npcs.rows(where.list).set(where.row, row);
        self.paths[index].clearRetainingCapacity();
    }

    /// The unit fell: its row moves to the fallen ones. NPCs get `dying_time` of death animation;
    /// a hero stays fallen until revived.
    pub fn fall(self: *Units, h: i64, dying_time: f32) !void {
        const where = self.locate(h) orelse return;
        if (where.list != .alive) return;
        self.bodyAt(where, "health").* = 0;
        self.bodyAt(where, "velocity").* = Vec3.zero;
        self.bodyAt(where, "dying_time").* = dying_time;
        if (where.kind == .npc) {
            const npc = self.npcs.alive.slice();
            npc.items(.target)[where.row] = handle.none;
            npc.items(.swing)[where.row].time = -1;
        }
        switch (where.kind) {
            inline else => |k| try self.storeOf(k).move(self.gpa, handle.indexOf(h), .fallen),
        }
    }

    /// A fallen hero gets up with `health`.
    pub fn rise(self: *Units, h: i64, health: f32) !void {
        const where = self.locate(h) orelse return;
        if (where.list != .fallen) return;
        self.bodyAt(where, "health").* = health;
        switch (where.kind) {
            inline else => |k| try self.storeOf(k).move(self.gpa, handle.indexOf(h), .alive),
        }
    }

    /// Gone for good: its index is free again and the handle stops resolving.
    pub fn release(self: *Units, h: i64) void {
        self.collect();
        const kind = handle.kindOf(h) orelse return;
        if (self.locate(h) == null) return;
        const index = handle.indexOf(h);
        if (kind == .npc) self.paths[index].clearRetainingCapacity();
        switch (kind) {
            inline else => |k| self.storeOf(k).release(index),
        }
    }

    pub fn clear(self: *Units) void {
        self.collect();
        self.heroes.clear();
        self.npcs.clear();
        self.summons.clear();
        for (&self.paths) |*path| path.clearRetainingCapacity();
    }

    pub fn define(self: *Units, index: usize, def: Def) !void {
        while (self.defs.items.len <= index) try self.defs.append(self.gpa, .{});
        self.defs.items[index] = def;
    }

    pub fn setLane(self: *Units, index: usize, spawn: Vec3, points: []const Vec3) !void {
        while (self.lanes.items.len <= index) try self.lanes.append(self.gpa, .{});
        try self.lanes.items[index].set(self.gpa, spawn, points);
    }

    /// The path NPC `h` follows from now on, from its start.
    pub fn setPath(self: *Units, h: i64, points: []const Vec3) !void {
        if (self.locate(h) == null or handle.kindOf(h) != .npc) return;
        const path = &self.paths[handle.indexOf(h)];
        path.clearRetainingCapacity();
        try path.appendSlice(self.gpa, points);
        self.brain(h, "path").?.index = 0;
    }

    // --- Seeing and fighting ---------------------------------------------------------------

    pub fn areEnemies(a: u8, b: u8) bool {
        return a != b and a != neutral_team and b != neutral_team;
    }

    /// Whether `team` sees a unit of `other_team` with these sight bits (noh CanSee): its own side
    /// always; neutrals have no sight of their own and see everyone.
    pub fn seesBits(team: u8, other_team: u8, sighted: i32) bool {
        return team == neutral_team or other_team == team or (sighted & (@as(i32, 1) << @intCast(team))) != 0;
    }

    pub fn sees(self: *Units, team: u8, h: i64) bool {
        const where = self.locate(h) orelse return false;
        return seesBits(team, self.bodyAt(where, "team").*, self.bodyAt(where, "sighted").*);
    }

    /// Flat distance between two units' edges; inf when either is gone.
    pub fn edgeDistance(self: *Units, a: i64, b: i64) f32 {
        const from = self.locate(a) orelse return std.math.inf(f32);
        const to = self.locate(b) orelse return std.math.inf(f32);
        return self.bodyAt(from, "position").flatDistance(self.bodyAt(to, "position").*) -
            self.bodyAt(from, "radius").* - self.bodyAt(to, "radius").*;
    }

    /// Nearest living enemy of `h` it sees within `scan_range` (edge to edge).
    pub fn findEnemy(self: *Units, h: i64, scan_range: f32) i64 {
        const me = self.locate(h) orelse return handle.none;
        const team = self.bodyAt(me, "team").*;
        const at = self.bodyAt(me, "position").*;
        const radius = self.bodyAt(me, "radius").*;
        var best = handle.none;
        var best_distance = std.math.inf(f32);
        inline for (handle.kinds) |k| {
            const s = self.storeOf(k).alive.slice();
            for (s.items(.team), s.items(.position), s.items(.radius), s.items(.sighted), s.items(.index)) |other_team, position, other_radius, sighted, index| {
                if (!areEnemies(other_team, team) or !seesBits(team, other_team, sighted)) continue;
                const distance = at.flatDistance(position) - radius - other_radius;
                if (distance <= scan_range and distance < best_distance) {
                    best_distance = distance;
                    best = self.handleOf(k, index);
                }
            }
        }
        return best;
    }

    /// noh IUnitEntity::GetThreatLevel, with fixed priorities instead of the combat type tables:
    /// creeps before summons before heroes, nearer before farther, the current target in attack range a
    /// little ahead. Only units the NPC's team sees count.
    pub fn bestTarget(self: *Units, row: usize, current: i64) i64 {
        const npc = self.npcs.alive.slice();
        const team = npc.items(.team)[row];
        const at = npc.items(.position)[row];
        const radius = npc.items(.radius)[row];
        const def = self.defs.items[npc.items(.definition)[row]];
        var best = handle.none;
        var best_threat = -std.math.inf(f32);
        inline for (handle.kinds) |k| {
            const s = self.storeOf(k).alive.slice();
            for (s.items(.team), s.items(.position), s.items(.radius), s.items(.sighted), s.items(.index)) |other_team, position, other_radius, sighted, index| {
                if (!areEnemies(other_team, team) or !seesBits(team, other_team, sighted)) continue;
                const distance = @max(at.flatDistance(position) - radius - other_radius, 0);
                if (distance > def.aggro_range) continue;
                const other = self.handleOf(k, index);
                const base: f32 = switch (k) {
                    .npc => threat_creep,
                    .summon => threat_summon,
                    else => threat_player_unit,
                };
                var threat = base - distance / def.aggro_range;
                if (other == current and distance <= def.attack_range) threat += threat_current_target;
                if (threat > best_threat) {
                    best_threat = threat;
                    best = other;
                }
            }
        }
        return best;
    }

    /// The best target for the NPC `h` right now, or none (for tests and tools).
    pub fn bestTargetOf(self: *Units, h: i64) i64 {
        const where = self.locate(h) orelse return handle.none;
        if (where.kind != .npc or where.list != .alive) return handle.none;
        return self.bestTarget(where.row, handle.none);
    }

    /// noh CBAttack's aggro trigger and IUnitEntity::AggroCreeps, for every attack order: ordering
    /// `attacker` to attack an enemy hero makes that hero's creeps around the attacker switch to the
    /// attacker for attack_aggro_time; attacking a creep pulls nothing. Ordering an attack on a
    /// friendly unit instead makes the enemy creeps that are after the attacker look for someone
    /// else: the de-aggro.
    pub fn attackOrderAggro(self: *Units, attacker: i64, target: i64) void {
        const source = self.locate(attacker) orelse return;
        const victim = self.locate(target) orelse return;
        const source_team = self.bodyAt(source, "team").*;
        const victim_team = self.bodyAt(victim, "team").*;
        const pull = areEnemies(victim_team, source_team);
        if (pull and victim.kind != .hero) return;
        const source_at = self.bodyAt(source, "position").*;
        const source_radius = self.bodyAt(source, "radius").*;
        const npc = self.npcs.alive.slice();
        for (0..self.npcs.alive.len) |row| {
            const team = npc.items(.team)[row];
            if (team == source_team) continue;
            if (npc.items(.position)[row].flatDistance(source_at) > attack_aggro_range + npc.items(.radius)[row] + source_radius) continue;
            if (pull) {
                // Only the target's own creeps, not siege, not already pulled
                if (team != victim_team or self.defs.items[npc.items(.definition)[row]].siege or npc.items(.aggro_until)[row] > self.clock) continue;
                npc.items(.target)[row] = attacker;
                npc.items(.aggro_until)[row] = self.clock + attack_aggro_time;
                npc.items(.swing)[row].time = -1; // noh ends the current attack behavior
            } else if (npc.items(.target)[row] == attacker) {
                npc.items(.target)[row] = handle.none;
                npc.items(.aggro_until)[row] = 0;
                npc.items(.timers)[row].scan = 0;
            }
        }
    }

    /// An NPC was hurt by `source`. A camp creature rouses its whole camp (every hit renews it);
    /// a creep without a target turns on an enemy attacker it sees (noh CBrain::Damaged).
    pub fn npcDamaged(self: *Units, victim: i64, source: i64) void {
        const where = self.locate(victim) orelse return;
        if (where.kind != .npc or where.list != .alive) return;
        const attacker = self.locate(source) orelse return;
        if (attacker.list != .alive) return;
        const npc = self.npcs.alive.slice();
        const team = npc.items(.team)[where.row];
        const source_team = self.bodyAt(attacker, "team").*;
        if (!areEnemies(source_team, team)) return;
        if (team == creature_team) {
            const lane = npc.items(.route)[where.row].lane;
            for (0..self.npcs.alive.len) |row| {
                const route = npc.items(.route)[row];
                if (route.lane != lane or npc.items(.position)[row].flatDistance(route.home) > camp_leash) continue;
                // The camp wakes up. A creature already fighting keeps at it; one with nobody yet picks the
                // best target near it (a summon before its master), or else whoever hit it. So a spell from
                // the hero behind her summon doesn't pull the camp off the summon.
                const target = &npc.items(.target)[row];
                if (!self.isAlive(target.*)) {
                    const best = self.bestTarget(row, handle.none);
                    target.* = if (best != handle.none) best else source;
                    npc.items(.swing)[row].time = -1; // a swing begun at nobody doesn't land on the newcomer
                }
                npc.items(.aggro_until)[row] = self.clock + camp_aggro_time;
            }
        } else if (!self.isAlive(npc.items(.target)[where.row]) and self.sees(team, source)) {
            const best = self.bestTarget(where.row, handle.none); // a summon near the attacker first
            npc.items(.target)[where.row] = if (best != handle.none) best else source;
        }
    }

    /// noh's forced attack order (Taunt): the NPC `victim` attacks `attacker` for `seconds`.
    pub fn forceAttack(self: *Units, victim: i64, attacker: i64, seconds: f64) void {
        const where = self.locate(victim) orelse return;
        if (where.kind != .npc or where.list != .alive or !self.isAlive(attacker)) return;
        const npc = self.npcs.alive.slice();
        if (npc.items(.target)[where.row] != attacker) npc.items(.swing)[where.row].time = -1; // a swing at the old target doesn't land on the new one
        npc.items(.target)[where.row] = attacker;
        npc.items(.aggro_until)[where.row] = self.clock + seconds; // like an aggro pull: no switching
        npc.items(.timers)[where.row].scan = behavior_update_time;
    }

    // --- Queries ---------------------------------------------------------------------------

    /// Living units whose center lies within `radius` of `center`.
    pub fn queryRadius(self: *Units, center: Vec3, radius: f32, out: *std.ArrayList(i64)) !void {
        inline for (handle.kinds) |k| {
            const s = self.storeOf(k).alive.slice();
            for (s.items(.position), s.items(.index)) |position, index| {
                if (position.distance(center) <= radius) try out.append(self.gpa, self.handleOf(k, index));
            }
        }
    }

    /// Handles of one kind's living (or fallen) rows, in row order: the order its columns come in.
    pub fn handlesOf(self: *Units, comptime kind: Kind, list: List, out: *std.ArrayList(i64)) !void {
        for (self.storeOf(kind).rows(list).items(.index)) |index| try out.append(self.gpa, self.handleOf(kind, index));
    }

    pub fn countAlive(self: *Units, kind: Kind, team: ?u8) usize {
        switch (kind) {
            inline else => |k| {
                const teams = self.storeOf(k).alive.items(.team);
                if (team == null) return teams.len;
                var total: usize = 0;
                for (teams) |t| total += @intFromBool(t == team.?);
                return total;
            },
        }
    }

    /// The living NPCs of a lane: its creeps, or a camp's creatures.
    pub fn npcsOf(self: *Units, lane: i16, out: *std.ArrayList(i64)) !void {
        const npc = self.npcs.alive.slice();
        for (npc.items(.route), npc.items(.index)) |route, index| {
            if (route.lane == lane) try out.append(self.gpa, self.handleOf(.npc, index));
        }
    }

    // --- Auras and highlights --------------------------------------------------------------

    pub fn clearAuras(self: *Units) void {
        inline for (handle.kinds) |k| {
            @memset(self.storeOf(k).alive.items(.bonus), .{});
        }
    }

    /// A hero's aura reaching its team within `radius` of `center`; same-kind auras don't stack
    /// (Warcraft III), so each unit keeps the strongest.
    pub fn applyAura(self: *Units, team: u8, center: Vec3, radius: f32, stat: Aura, amount: f32) void {
        inline for (handle.kinds) |k| {
            const s = self.storeOf(k).alive.slice();
            for (s.items(.team), s.items(.position), s.items(.bonus)) |t, position, *bonus| {
                if (t != team or position.distance(center) > radius) continue;
                switch (stat) {
                    .armor => bonus.armor = @max(bonus.armor, amount),
                    .ranged_damage_percent => bonus.ranged = @max(bonus.ranged, amount * 0.01),
                    .mana_regen => bonus.mana_regen = @max(bonus.mana_regen, amount),
                }
            }
        }
    }

    pub fn clearHighlights(self: *Units) void {
        inline for (handle.kinds) |k| {
            for (self.storeOf(k).alive.items(.look)) |*look| look.highlight = 0;
        }
    }

    // --- Sight ------------------------------------------------------------------------------

    /// noh's "update sight flags" pass: every unit's sight bits from the teams' latest maps (its
    /// own team always; a stealthed unit only that), plus the teams it attacked within
    /// `aggression_time` seconds. With the fog of war off everyone sees everyone.
    pub fn updateSight(self: *Units, enabled: bool, aggression_time: f64) void {
        const since = self.clock - aggression_time;
        inline for (handle.kinds) |k| {
            inline for (.{ List.alive, List.fallen }) |list| {
                const s = self.storeOf(k).rows(list).slice();
                for (s.items(.sighted), s.items(.team), s.items(.stealthed), s.items(.position), s.items(.aggressions)) |*sighted, team, stealthed, position, aggressions| {
                    sighted.* = if (enabled) self.sight.bitsFor(team, stealthed, position, aggressions, since) else -1;
                }
            }
        }
    }

    // --- The tick --------------------------------------------------------------------------

    /// One tick: the paths asked for last tick, tick(), the engine's answers (resolve()), finish().
    pub fn step(self: *Units, delta: f32) !void {
        self.collect();
        try self.tick(delta);
        try self.resolve();
        self.finish(delta);
    }

    /// Starts the threads on the tick's corners and path requests (collect() brings their
    /// answers in).
    pub fn resolve(self: *Units) !void {
        const nav = self.nav orelse return;
        const count = self.path_requests.items.len + self.corners.items.len;
        if (count == 0) return;
        const flight = &self.flight;
        // The questions go in flight; this tick's lists start empty next tick
        std.mem.swap(std.ArrayList(i64), &flight.corners, &self.corners);
        std.mem.swap(std.ArrayList(Vec3), &flight.corner_points, &self.corner_points);
        try flight.closest.resize(self.gpa, flight.corners.items.len);
        std.mem.swap(std.ArrayList(i64), &flight.requests, &self.path_requests);
        std.mem.swap(std.ArrayList(Vec3), &flight.froms, &self.path_froms);
        std.mem.swap(std.ArrayList(Vec3), &flight.goals, &self.path_goals);
        while (flight.answers.items.len < flight.requests.items.len) try flight.answers.append(self.gpa, .empty);
        flight.next_corner.store(0, .monotonic);
        flight.next.store(0, .monotonic);
        flight.nav = nav;
        flight.gpa = self.gpa;
        flight.busy = true;
        const threads = @min(count, @max(self.path_threads, 1), flight.workers.len);
        for (flight.workers[0..threads]) |*worker| {
            worker.* = std.Thread.spawn(.{}, Flight.work, .{flight}) catch null;
        }
        if (flight.workers[0] == null) flight.work(); // no thread to be had: answer them here
    }

    /// Waits for the answers in flight, if any: NPCs stuck at a corner go to the closest walkable
    /// point, and each path takes the place of the one its NPC had (unless the NPC is gone since).
    pub fn collect(self: *Units) void {
        const flight = &self.flight;
        if (!flight.busy) return;
        for (&flight.workers) |*worker| {
            if (worker.*) |thread| thread.join();
            worker.* = null;
        }
        flight.busy = false;
        for (flight.corners.items, flight.closest.items) |h, moved| {
            if (!self.isAlive(h)) continue;
            const position = self.body(h, "position").?;
            position.* = .{ .x = moved.x, .y = position.y, .z = moved.z };
        }
        flight.corners.clearRetainingCapacity();
        flight.corner_points.clearRetainingCapacity();
        for (flight.requests.items, flight.answers.items[0..flight.requests.items.len]) |h, *answer| {
            const state = self.brain(h, "path") orelse continue;
            std.mem.swap(std.ArrayList(Vec3), &self.paths[handle.indexOf(h)], answer);
            state.index = 0;
        }
        flight.requests.clearRetainingCapacity();
        flight.froms.clearRetainingCapacity();
        flight.goals.clearRetainingCapacity();
    }

    /// Puts a unit somewhere at once: drawn there too, not slid from where it was.
    pub fn teleport(self: *Units, h: i64, position: Vec3, yaw: f32) void {
        const where = self.locate(h) orelse return;
        self.bodyAt(where, "position").* = position;
        self.bodyAt(where, "yaw").* = yaw;
        const look = self.bodyAt(where, "look");
        look.previous = position;
        look.previous_yaw = yaw;
    }

    /// Where to draw a unit `alpha` (0-1) of the way from the last tick to the next: between
    /// where it was when the tick started and where it is now.
    pub fn displayPosition(look: rows.Look, position: Vec3, alpha: f32) Vec3 {
        return look.previous.add(position.sub(look.previous).scale(alpha));
    }

    pub fn displayYaw(look: rows.Look, yaw: f32, alpha: f32) f32 {
        return look.previous_yaw + vec.angleDifference(look.previous_yaw, yaw) * alpha;
    }

    // --- Fog of war ------------------------------------------------------------------------

    /// noh's visibility update: every unit that sees (living ones, and fallen heroes) casts its
    /// sight into its team's map, eyes `eye_height` above its ground; the finished maps replace
    /// the last ones. The player's team always has a map.
    pub fn updateFog(self: *Units, eye_height: f32, player_team: u8) !void {
        const sight = &self.sight;
        if (sight.heights.len == 0) return;
        try sight.ensureTeam(self.gpa, player_team);
        sight.startUpdate();
        inline for (handle.kinds) |k| {
            inline for (.{ List.alive, List.fallen }) |list| {
                if (list == .fallen and k != .hero) continue; // fallen NPCs and summons see nothing
                const s = self.storeOf(k).rows(list).slice();
                for (s.items(.team), s.items(.definition), s.items(.position)) |team, definition, position| {
                    if (team == neutral_team or definition >= self.defs.items.len) continue; // neutrals have no vision of their own
                    const def = self.defs.items[definition];
                    if (def.sight_range <= 0) continue;
                    const eye = if (def.clear_vision) std.math.inf(f32) else sight.eyeAt(position, eye_height);
                    try sight.look(self.gpa, team, position, eye, def.sight_range);
                }
            }
        }
        sight.publish();
    }

    /// One unit's sight bits from the current maps (updateSight does every unit's).
    pub fn sightBitsOf(self: *Units, h: i64, enabled: bool, aggression_time: f64) i32 {
        if (!enabled) return -1;
        const where = self.locate(h) orelse return 0;
        return self.sight.bitsFor(self.bodyAt(where, "team").*, self.bodyAt(where, "stealthed").*, self.bodyAt(where, "position").*,
            self.bodyAt(where, "aggressions").*, self.clock - aggression_time);
    }

    pub fn tick(self: *Units, delta: f32) !void {
        const gpa = self.gpa;
        self.clock += delta;
        inline for (.{ &self.buried, &self.corners, &self.landed_sources, &self.landed_targets, &self.path_requests }) |list| list.clearRetainingCapacity();
        inline for (.{ &self.corner_points, &self.path_froms, &self.path_goals }) |list| list.clearRetainingCapacity();

        inline for (handle.kinds) |k| {
            for (self.storeOf(k).alive.items(.look)) |*look| look.flash_time = @max(look.flash_time - delta, 0);
        }
        inline for (.{ List.alive, List.fallen }) |list| {
            const npc = self.npcs.rows(list).slice();
            for (npc.items(.look), npc.items(.position), npc.items(.yaw)) |*look, position, yaw| {
                look.previous = position;
                look.previous_yaw = yaw;
            }
        }
        // Fallen NPCs whose death animation is over become corpses (GDScript buries them)
        {
            const fallen = self.npcs.fallen.slice();
            for (fallen.items(.dying_time), fallen.items(.index)) |*time, index| {
                time.* -= delta;
                if (time.* <= 0) try self.buried.append(gpa, self.handleOf(.npc, index));
            }
        }
        // Moving: the avoidance velocity computed for the last tick, staying on walkable ground
        {
            const npc = self.npcs.alive.slice();
            for (npc.items(.position), npc.items(.velocity), npc.items(.safe_velocity), npc.items(.anchored), npc.items(.index)) |*position, *velocity, safe, anchored, index| {
                var moving = if (anchored) Vec3.zero else safe;
                moving.y = 0;
                velocity.* = moving;
                if (moving.lengthSquared() < 0.001) continue;
                const wanted = position.add(moving.scale(delta));
                if (self.grid.step(position.*, wanted)) |moved| {
                    position.* = .{ .x = moved.x, .y = position.y, .z = moved.z };
                } else {
                    try self.corners.append(gpa, self.handleOf(.npc, index)); // a corner the grid can't tell
                    try self.corner_points.append(gpa, wanted);
                }
            }
        }
        for (0..self.npcs.alive.len) |row| try self.think(row, delta);
    }

    fn think(self: *Units, row: usize, delta: f32) !void {
        const npc = self.npcs.alive.slice();
        const def = self.defs.items[npc.items(.definition)[row]];
        const timers = &npc.items(.timers)[row];
        const attack_delta = delta * (1 - npc.items(.status)[row].attack_slow); // a chill slows its attacks
        timers.cooldown = @max(timers.cooldown - attack_delta, 0);
        timers.scan -= delta;
        timers.repath -= delta;
        npc.items(.anchored)[row] = false;
        npc.items(.path)[row].seeking = false;
        npc.items(.desired)[row] = Vec3.zero;

        if (npc.items(.status)[row].stunned) {
            npc.items(.anchored)[row] = true;
            npc.items(.swing)[row].time = -1;
        } else if (npc.items(.route)[row].lane < 0) {
            npc.items(.anchored)[row] = true; // neutral: stands still, turned toward whoever talks to it
        } else if (npc.items(.swing)[row].time >= 0) {
            npc.items(.anchored)[row] = true;
            try self.updateSwing(row, def, attack_delta);
        } else {
            try self.attackMove(row, def);
        }
    }

    fn updateSwing(self: *Units, row: usize, def: Def, delta: f32) !void {
        const npc = self.npcs.alive.slice();
        const swing = &npc.items(.swing)[row];
        swing.time += delta;
        if (!swing.landed and swing.time >= def.attack_point) {
            swing.landed = true;
            const target = npc.items(.target)[row];
            if (self.isAlive(target)) {
                try self.landed_sources.append(self.gpa, self.handleOf(.npc, npc.items(.index)[row]));
                try self.landed_targets.append(self.gpa, target);
            }
        }
        if (swing.time >= def.attack_point + def.attack_backswing) swing.time = -1;
    }

    /// noh creeps: attack-move towards the next lane waypoint, fighting whatever comes into aggro
    /// range on the way. Like CBAttackMove::UpdateAggro the target is chosen again every
    /// behavior_update_time by threat, except while an aggro pull lasts.
    fn attackMove(self: *Units, row: usize, def: Def) !void {
        const npc = self.npcs.alive.slice();
        const at = npc.items(.position)[row];
        const team = npc.items(.team)[row];
        const route = &npc.items(.route)[row];
        const lane = self.lanes.items[@intCast(route.lane)];
        const has_lane = lane.hasNodes();
        route.waypoint = if (has_lane) lane.next(at, route.waypoint) else route.home;

        var target = npc.items(.target)[row];
        var target_where = self.locate(target);
        if (target_where) |where| {
            if (where.list != .alive or !seesBits(team, self.bodyAt(where, "team").*, self.bodyAt(where, "sighted").*))
                target_where = null; // noh ShouldTarget: dead, or gone into the fog
        }
        var pulled = target_where != null and npc.items(.aggro_until)[row] > self.clock;
        if (target_where != null and !has_lane and at.flatDistance(route.home) > camp_leash) {
            target_where = null; // a camp creature led too far from its spot: back home
            pulled = false;
            npc.items(.aggro_until)[row] = 0;
        }
        if (!pulled) {
            if (target_where != null and self.edgeDistance(self.handleOf(.npc, npc.items(.index)[row]), target) > def.aggro_range * leash_factor)
                target_where = null;
            const timers = &npc.items(.timers)[row];
            if (timers.scan <= 0) {
                timers.scan = behavior_update_time;
                target = self.bestTarget(row, if (target_where != null) target else handle.none);
                target_where = self.locate(target);
            }
        }
        if (target_where == null) target = handle.none;
        npc.items(.target)[row] = target;

        if (target_where == null) {
            if (!has_lane and at.flatDistance(route.home) < home_reached) {
                npc.items(.anchored)[row] = true; // back at its own spot in the camp: out of everyone's way
                return;
            }
            return self.seek(row, route.waypoint);
        }
        const target_at = self.bodyAt(target_where.?, "position").*;
        const edge = at.flatDistance(target_at) - npc.items(.radius)[row] - self.bodyAt(target_where.?, "radius").*;
        if (edge <= def.attack_range) {
            npc.items(.anchored)[row] = true;
            if (npc.items(.timers)[row].cooldown <= 0) {
                npc.items(.swing)[row] = .{ .time = 0, .landed = false };
                npc.items(.timers)[row].cooldown = def.attack_cooldown;
                npc.items(.anim)[row] = 0; // restart the attack clip
            }
            return;
        }
        return self.seek(row, target_at);
    }

    /// Walks toward `goal`: asks for a new path when the old one is stale or leads elsewhere.
    fn seek(self: *Units, row: usize, goal: Vec3) !void {
        const npc = self.npcs.alive.slice();
        const path = &npc.items(.path)[row];
        path.seeking = true;
        const timers = &npc.items(.timers)[row];
        if (timers.repath <= 0 or goal.flatDistance(path.goal) > repath_distance) {
            const index = npc.items(.index)[row];
            try self.path_requests.append(self.gpa, self.handleOf(.npc, index));
            try self.path_froms.append(self.gpa, npc.items(.position)[row]);
            try self.path_goals.append(self.gpa, goal);
            path.goal = goal; // it walks its old path until the new one comes (collect, next tick)
            timers.repath = repath_time;
        }
    }

    /// The second half of a tick, once GDScript has answered the path requests.
    pub fn finish(self: *Units, delta: f32) void {
        const npc = self.npcs.alive.slice();
        for (0..self.npcs.alive.len) |row| {
            const state = &npc.items(.path)[row];
            if (state.seeking) {
                const at = npc.items(.position)[row];
                const points = self.paths[npc.items(.index)[row]].items;
                var index: usize = state.index;
                while (index < points.len and at.flatDistance(points[index]) < path_point_reached) index += 1;
                state.index = @intCast(@min(index, std.math.maxInt(u16)));
                if (index < points.len) {
                    const def = self.defs.items[npc.items(.definition)[row]];
                    const speed = def.move_speed * (1 - npc.items(.status)[row].slow);
                    npc.items(.desired)[row] = points[index].sub(at).flat().normalized().scale(speed);
                }
            }
            self.turn(row, delta);
        }
    }

    fn turn(self: *Units, row: usize, delta: f32) void {
        const npc = self.npcs.alive.slice();
        const at = npc.items(.position)[row];
        var look = Vec3.zero;
        if (self.body(npc.items(.listening)[row], "position")) |listener| {
            look = listener.sub(at);
        } else if (npc.items(.anchored)[row] and self.isAlive(npc.items(.target)[row])) {
            look = self.body(npc.items(.target)[row], "position").?.sub(at);
        } else if (npc.items(.velocity)[row].lengthSquared() > 0.25) {
            look = npc.items(.velocity)[row];
        }
        if (look.x * look.x + look.z * look.z < 0.0001) return;
        const def = self.defs.items[npc.items(.definition)[row]];
        // KayKit models face +Z
        const yaw = &npc.items(.yaw)[row];
        yaw.* = vec.rotateToward(yaw.*, std.math.atan2(look.x, look.z), def.turn_rate * delta);
    }

    // --- Saving ----------------------------------------------------------------------------

    /// The clock and every store, as bytes. Lanes, definitions and the walk grid come from the
    /// map and its resources, and paths are asked for again.
    pub fn save(self: *Units, out: *std.ArrayList(u8)) !void {
        var clock: [8]u8 = undefined;
        std.mem.writeInt(u64, &clock, @bitCast(self.clock), .little);
        try out.appendSlice(self.gpa, &clock);
        inline for (handle.kinds) |k| {
            var part: std.ArrayList(u8) = .empty;
            defer part.deinit(self.gpa);
            try self.storeOf(k).save(self.gpa, &part);
            var size: [4]u8 = undefined;
            std.mem.writeInt(u32, &size, @intCast(part.items.len), .little);
            try out.appendSlice(self.gpa, &size);
            try out.appendSlice(self.gpa, part.items);
        }
    }

    /// False when the bytes don't fit (a save from another layout of the rows).
    pub fn load(self: *Units, bytes: []const u8) !bool {
        if (bytes.len < 8) return false;
        self.collect();
        self.clear();
        self.clock = @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
        var at: usize = 8;
        inline for (handle.kinds) |k| {
            if (at + 4 > bytes.len) return false;
            const size = std.mem.readInt(u32, bytes[at..][0..4], .little);
            at += 4;
            if (at + size > bytes.len) return false;
            if (!try self.storeOf(k).load(self.gpa, bytes[at .. at + size])) return false;
            at += size;
        }
        return true;
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const handle = @import("handle.zig");
const Kind = handle.Kind;
const store_ = @import("store.zig");
const Store = store_.Store;
const List = store_.List;
const rows = @import("rows.zig");
const Def = rows.Def;
const vec = @import("vec.zig");
const Vec3 = vec.Vec3;
const WalkGrid = @import("grid.zig").WalkGrid;
const Sight = @import("sight.zig").Sight;
const Lane = @import("lane.zig").Lane;

// --- Tests -------------------------------------------------------------------------------------

fn testUnits() !Units {
    var units = Units.init(std.testing.allocator);
    try units.define(0, .{ .move_speed = 4, .aggro_range = 8, .attack_range = 1.2, .attack_cooldown = 1, .attack_point = 0.3, .attack_backswing = 0.3 });
    try units.setLane(0, .{ .z = 50 }, &.{ .{ .z = 0 }, .{ .z = -50 } }); // south to north
    try units.setLane(1, .{ .z = -50 }, &.{ .{ .z = 0 }, .{ .z = 50 } }); // north to south
    try units.grid.set(std.testing.allocator, -100, -100, 200, 200, 1, &(@as([40000]u8, @splat(1))));
    return units;
}

fn creep(units: *Units, team: u8, lane: i16, at: Vec3) !i64 {
    const h = try units.create(.npc, .{ .team = team, .position = at, .health = 100, .max_health = 100 });
    units.startNpc(h, lane, at, 0);
    return h;
}

fn tickAll(units: *Units, delta: f32) !void {
    try units.tick(delta);
    // Straight-line paths stand in for the NavigationServer's
    for (units.path_requests.items, units.path_goals.items) |h, goal| try units.setPath(h, &.{goal});
    units.finish(delta);
    // The avoidance would answer with the desired velocity
    const npc = units.npcs.alive.slice();
    for (npc.items(.desired), npc.items(.safe_velocity)) |desired, *safe| safe.* = desired;
}

test "creeps walk their lane, meet, fight" {
    var units = try testUnits();
    defer units.deinit();
    const south = try creep(&units, 1, 0, .{ .z = 20 });
    const north = try creep(&units, 2, 1, .{ .z = -20 });
    try std.testing.expectEqual(Kind.npc, handle.kindOf(south).?);
    var landed: usize = 0;
    for (0..600) |_| {
        try tickAll(&units, 1.0 / 60.0);
        landed += units.landed_sources.items.len;
    }
    try std.testing.expectEqual(north, units.brain(south, "target").?.*);
    try std.testing.expectEqual(south, units.brain(north, "target").?.*);
    try std.testing.expect(units.edgeDistance(south, north) <= 1.3);
    try std.testing.expect(landed > 4);
}

test "attacking a hero pulls its creeps; attacking a creep doesn't" {
    var units = try testUnits();
    defer units.deinit();
    const hero = try units.create(.hero, .{ .team = 2, .position = .{ .x = 3 }, .health = 500 });
    const guard = try creep(&units, 2, 1, .{ .x = 4 });
    const attacker = try units.create(.hero, .{ .team = 1, .position = .{}, .health = 500 });
    units.attackOrderAggro(attacker, guard);
    try std.testing.expectEqual(handle.none, units.brain(guard, "target").?.*);
    units.attackOrderAggro(attacker, hero);
    try std.testing.expectEqual(attacker, units.brain(guard, "target").?.*);
}

test "a hit rouses the whole camp; they go home when led too far" {
    var units = try testUnits();
    defer units.deinit();
    try units.setLane(2, .{ .x = 30 }, &.{}); // a camp: no lane nodes
    const a = try creep(&units, creature_team, 2, .{ .x = 30 });
    const b = try creep(&units, creature_team, 2, .{ .x = 31 });
    const hero = try units.create(.hero, .{ .team = 1, .position = .{ .x = 25 }, .health = 500 });
    units.npcDamaged(a, hero);
    try std.testing.expectEqual(hero, units.brain(b, "target").?.*);
    // The hero runs off: past the leash they drop it and walk back
    units.body(hero, "position").?.* = .{ .x = -10 };
    for (0..1200) |_| try tickAll(&units, 1.0 / 60.0);
    try std.testing.expectEqual(handle.none, units.brain(a, "target").?.*);
    try std.testing.expect(units.body(a, "position").?.flatDistance(.{ .x = 30 }) < home_reached + 0.1);
}

test "a summon near its master draws the enemies, and a camp fighting it isn't pulled off by her spells" {
    var units = try testUnits();
    defer units.deinit();
    try units.setLane(2, .{ .x = 30 }, &.{}); // a camp: no lane nodes
    const a = try creep(&units, creature_team, 2, .{ .x = 30 });
    const b = try creep(&units, creature_team, 2, .{ .x = 31 });
    // Maren a little nearer than Brook: Brook still comes first
    const maren = try units.create(.hero, .{ .team = 1, .position = .{ .x = 28 }, .health = 500 });
    const brook = try units.create(.summon, .{ .team = 1, .position = .{ .x = 27.5, .z = 1 }, .health = 500 });
    try std.testing.expectEqual(brook, units.bestTargetOf(a));
    // Maren's spell wakes the camp: they go for Brook, beside her; another of her spells: they stay on him
    units.npcDamaged(a, maren);
    try std.testing.expectEqual(brook, units.brain(b, "target").?.*);
    units.npcDamaged(b, maren);
    try std.testing.expectEqual(brook, units.brain(a, "target").?.*);
    try std.testing.expectEqual(brook, units.brain(b, "target").?.*);
}

test "a forced target change ends the swing at the old target" {
    var units = try testUnits();
    defer units.deinit();
    const a = try creep(&units, 2, 0, .{});
    const first = try units.create(.hero, .{ .team = 1, .position = .{ .x = 1 }, .health = 500 });
    const second = try units.create(.hero, .{ .team = 1, .position = .{ .x = 15 }, .health = 500 });
    units.brain(a, "target").?.* = first;
    units.brain(a, "swing").?.* = .{ .time = 0.1, .landed = false };
    units.forceAttack(a, second, 3);
    try std.testing.expect(units.brain(a, "swing").?.time < 0);
    try std.testing.expectEqual(second, units.brain(a, "target").?.*);
}

test "the fallen move out of the living rows and get buried" {
    var units = try testUnits();
    defer units.deinit();
    const a = try creep(&units, 1, 0, .{ .z = 20 });
    const b = try creep(&units, 1, 0, .{ .z = 22 });
    try units.fall(a, 1.0);
    try std.testing.expectEqual(Life.dying, units.lifeOf(a));
    try std.testing.expectEqual(@as(usize, 1), units.countAlive(.npc, null));
    try std.testing.expect(units.isAlive(b));
    var buried = false;
    for (0..70) |_| {
        try tickAll(&units, 1.0 / 60.0);
        for (units.buried.items) |h| {
            if (h == a) buried = true;
        }
    }
    try std.testing.expect(buried);
    units.release(a);
    try std.testing.expectEqual(Life.free, units.lifeOf(a));
    // Heroes stay fallen until revived
    const hero = try units.create(.hero, .{ .team = 1, .health = 300, .max_health = 300 });
    try units.fall(hero, 0);
    try std.testing.expectEqual(Life.dead, units.lifeOf(hero));
    try units.rise(hero, 150);
    try std.testing.expect(units.isAlive(hero));
    try std.testing.expectEqual(@as(f32, 150), units.body(hero, "health").?.*);
}

test "a saved registry loads with the same handles" {
    var units = try testUnits();
    defer units.deinit();
    const a = try creep(&units, 1, 0, .{ .z = 20 });
    const hero = try units.create(.hero, .{ .team = 1, .health = 300 });
    try tickAll(&units, 0.5);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.testing.allocator);
    try units.save(&bytes);
    var loaded = try testUnits();
    defer loaded.deinit();
    try std.testing.expect(try loaded.load(bytes.items));
    try std.testing.expect(loaded.isAlive(a) and loaded.isAlive(hero));
    try std.testing.expectEqual(units.body(a, "position").?.*, loaded.body(a, "position").?.*);
    try std.testing.expectEqual(units.clock, loaded.clock);
}

test "sight bits come from the team maps, stealth and attacks" {
    var units = try testUnits();
    defer units.deinit();
    units.sight.setLayout(std.testing.allocator, 0, 0, 1, 4, 4, 0);
    var seen: [16]u8 = @splat(0);
    seen[1 * 4 + 1] = 255; // team 2 sees the cell at x 1, z 1
    try units.sight.setMap(std.testing.allocator, 2, &seen);
    try units.sight.setMap(std.testing.allocator, 1, &(@as([16]u8, @splat(0))));
    const seen_creep = try units.create(.npc, .{ .team = 1, .position = .{ .x = 1.5, .z = 1.5 } });
    const hidden = try units.create(.npc, .{ .team = 1, .position = .{ .x = 3.5, .z = 3.5 } });
    const sneaky = try units.create(.hero, .{ .team = 1, .position = .{ .x = 1.5, .z = 1.5 }, .stealthed = true });
    units.updateSight(true, 3);
    try std.testing.expectEqual(@as(i32, 0b110), units.body(seen_creep, "sighted").?.*);
    try std.testing.expectEqual(@as(i32, 0b010), units.body(hidden, "sighted").?.*);
    try std.testing.expectEqual(@as(i32, 0b010), units.body(sneaky, "sighted").?.*);
    // Attacking team 2 a moment ago shows it to team 2 wherever it is
    units.body(hidden, "aggressions").?[2] = units.clock;
    units.updateSight(true, 3);
    try std.testing.expectEqual(@as(i32, 0b110), units.body(hidden, "sighted").?.*);
}

/// Straight lines for paths, and every point is walkable.
const StraightNavigator = struct {
    fn closestPoint(_: *anyopaque, point: Vec3) Vec3 {
        return point;
    }

    fn path(_: *anyopaque, from: Vec3, to: Vec3, gpa: Allocator, out: *std.ArrayList(Vec3)) void {
        out.clearRetainingCapacity();
        out.appendSlice(gpa, &.{ from, to }) catch {};
    }
};

test "a step answers path requests through the navigator, several threads at once" {
    const gpa = std.heap.smp_allocator; // the threads allocate at the same time
    var units = Units.init(gpa);
    defer units.deinit();
    try units.define(0, .{ .move_speed = 4 });
    try units.setLane(0, .{ .z = 50 }, &.{ .{ .z = 0 }, .{ .z = -50 } });
    try units.grid.set(gpa, -100, -100, 200, 200, 1, &(@as([40000]u8, @splat(1))));
    var context: u8 = 0;
    units.nav = .{ .context = &context, .closestPoint = StraightNavigator.closestPoint, .path = StraightNavigator.path };
    units.path_threads = 4;
    var creeps: [40]i64 = undefined;
    for (&creeps, 0..) |*h, i| {
        const at: Vec3 = .{ .x = @floatFromInt(@as(i32, @intCast(i)) - 20), .z = 40 };
        h.* = try units.create(.npc, .{ .team = 1, .position = at, .health = 10, .max_health = 10 });
        units.startNpc(h.*, 0, at, 1); // no target scan this tick: every creep walks
    }
    try units.step(0.1);
    try std.testing.expectEqual(@as(usize, 40), units.flight.requests.items.len); // in flight
    try std.testing.expect(units.brain(creeps[0], "desired").?.lengthSquared() == 0); // no path yet: it stands
    try units.step(0.1); // the answers come in, and they walk
    for (creeps) |h| {
        try std.testing.expectEqual(@as(usize, 2), units.paths[handle.indexOf(h)].items.len);
        try std.testing.expect(units.brain(h, "desired").?.z < -1); // heading north along the lane
    }
}

test "between ticks a creep is drawn between where it was and where it is" {
    var units = try testUnits();
    defer units.deinit();
    const h = try creep(&units, 1, 0, .{ .z = 20 });
    try tickAll(&units, 0.1); // asks for a path, stands
    try tickAll(&units, 0.1); // walks off at its avoidance velocity
    try tickAll(&units, 0.1);
    const look = units.body(h, "look").?.*;
    const now = units.body(h, "position").?.*;
    try std.testing.expect(now.z < look.previous.z);
    const halfway = Units.displayPosition(look, now, 0.5);
    try std.testing.expectApproxEqAbs((look.previous.z + now.z) / 2, halfway.z, 0.001);
    // A teleport isn't drawn as a slide
    units.teleport(h, .{ .x = 5, .z = 5 }, 1);
    const moved = units.body(h, "look").?.*;
    try std.testing.expectEqual(@as(f32, 5), Units.displayPosition(moved, units.body(h, "position").?.*, 0.3).x);
}

test "the fog cast reaches each team's map, and neutrals see nothing" {
    var units = try testUnits();
    defer units.deinit();
    try units.define(1, .{ .sight_range = 6 });
    units.sight.setLayout(std.testing.allocator, -50, -50, 1, 100, 100, 10);
    const cells = units.sight.cellCount();
    const zeros = try std.testing.allocator.alloc(f32, cells);
    defer std.testing.allocator.free(zeros);
    @memset(zeros, 0);
    try units.sight.setOcclusion(std.testing.allocator, zeros, zeros);
    _ = try units.create(.hero, .{ .team = 1, .definition = 1, .position = .{ .x = 10, .z = 10 }, .health = 1 });
    _ = try units.create(.npc, .{ .team = neutral_team, .definition = 1, .position = .{ .x = -10, .z = -10 }, .health = 1 });
    const watched = try units.create(.npc, .{ .team = 2, .definition = 0, .position = .{ .x = 13, .z = 10 }, .health = 1 });
    try units.updateFog(1.3, 1);
    try std.testing.expect(units.sight.maps[1][units.sight.cellIndex(.{ .x = 14, .z = 10 })] != 0);
    try std.testing.expect(units.sight.maps[1][units.sight.cellIndex(.{ .x = -10, .z = -10 })] == 0);
    try std.testing.expectEqual(@as(usize, 0), units.sight.maps[neutral_team].len);
    try std.testing.expect(units.sightBitsOf(watched, true, 3) & (1 << 1) != 0); // team 1 sees it
}
