//! UnitStore: the unit registry's core (src/core/units.zig) as a Godot class. UnitRegistry
//! (scripts/rts/unit_registry.gd) adds one as its child and calls in for the units' data and the
//! loops over it; it keeps the rules that need the game's resources.
//!
//! step() is a whole tick of the creeps: the core's tick, the NavigationServer's answers, and the
//! NPCs' avoidance agents told where they are and where they want to go (they answer through
//! avoided()). Path requests are worked out on several threads (the NavigationServer's queries are
//! thread-safe) while the rest of the frame goes on, and come in at the next step.
//!
//! Handles are GDScript ints: generation << 12 | kind << 9 | index (UnitRegistry.Kind order).
//! Per-unit getters answer a default (0, Vector3.ZERO, -1 for handles) for a handle that doesn't
//! resolve. Bulk columns (`*_column`) hand over one field of a kind's living or fallen rows in
//! row order, the order `handles()` lists them in: one call a frame instead of one per unit.
const UnitStore = @This();

pub fn register(r: *Registry) void {
    const class = r.createClass(UnitStore, r.allocator, .auto);
    inline for (.{
        // Setup
        "define",               "set_lane",            "set_walk_grid",     "set_navigation_map", "set_agent",
        "set_path_threads",
        // Units coming and going
        "add_unit",             "start_npc",           "fall",              "rise",               "release",
        "clear_all",            "life_of",             "is_alive",
        // One unit's body
        "position_of",          "yaw_of",              "velocity_of",       "radius_of",          "height_of",
        "scale_of",             "team_of",             "definition_of",     "health_of",          "max_health_of",
        "armor_of",             "armor_type_of",       "evasion_of",        "parry_of",           "spell_damage_of",
        "is_invulnerable",      "is_stealthed",        "sighted_of",        "highlight_of",       "flash_time_of",
        "flash_color_of",       "armor_bonus_of",      "ranged_bonus_of",   "mana_regen_bonus_of", "last_aggression",
        "dying_time_of",
        "set_position",         "set_yaw",             "set_velocity",      "set_health",         "set_max_health",
        "teleport",
        "set_combat",           "set_invulnerable",    "set_stealthed",     "set_sighted",        "raise_highlight",
        "clear_highlights",     "flash",               "set_aggression",
        // One NPC's brain
        "target_of",            "lane_of",             "home_of",           "swing_of",           "is_anchored",
        "anim_of",              "aggro_until_of",      "desired_of",
        "set_target",           "set_lane_of",         "set_status",        "avoided",            "set_listening",
        "set_anim",
        // Queries
        "count_alive",          "handles",             "npcs_of",           "query_radius",       "find_enemy",
        "edge_distance",        "sees",                "best_target",
        // Aggro
        "attack_order_aggro",   "npc_damaged",         "force_attack",
        // Auras and sight
        "clear_auras",          "apply_aura",          "set_sight_layout",  "set_sight_occlusion", "update_fog",
        "update_sight",         "sight_map",           "sight_bits_of",
        // The tick
        "step",                 "buried",              "landed_sources",    "landed_targets",    "step_profile",
        // Bulk columns
        "vec3_column",          "float_column",        "int_column",        "color_column",      "display_positions",
        "display_yaws",
        // Saving
        "save",                 "load",                "now",               "set_clock",
    }) |name| class.addMethod(name, .auto);
}

pub fn unregister(r: *Registry) void {
    r.removeClass(UnitStore);
}

allocator: Allocator,
base: *Node,
units: core.Units,
/// The world's navigation map; invalid until set_navigation_map.
map: Rid = std.mem.zeroes(Rid),
/// The last step's parts in microseconds (waiting for the paths in flight, tick, corners and
/// starting the path threads, finish, agents), and how many paths it asked for.
profile: [6]f32 = @splat(0),
/// Each NPC index's avoidance agent; invalid (zero) for none.
agents: [core.handle.per_kind]Rid = @splat(std.mem.zeroes(Rid)),

pub fn create(allocator: *Allocator) !*UnitStore {
    const self = try allocator.create(UnitStore);
    self.* = .{ .allocator = allocator.*, .base = Node.init(), .units = .init(allocator.*) };
    self.base.setInstance(UnitStore, self);
    return self;
}

pub fn recreate(allocator: *Allocator, obj: *Object) *UnitStore {
    const self = allocator.create(UnitStore) catch @panic("OOM");
    self.* = .{ .allocator = allocator.*, .base = @ptrCast(obj), .units = .init(allocator.*) };
    self.base.setInstance(UnitStore, self);
    return self;
}

pub fn destroy(self: *UnitStore, allocator: *Allocator) void {
    self.units.deinit();
    self.base.destroy();
    allocator.destroy(self);
}

// --- Setup ---------------------------------------------------------------------------------

/// What the creep behavior needs to know about definition `index` (UnitRegistry.definitions).
pub fn define(self: *UnitStore, index: i64, move_speed: f64, aggro_range: f64, attack_range: f64, attack_point: f64,
    attack_backswing: f64, attack_cooldown: f64, turn_rate: f64, siege: bool, sight_range: f64, clear_vision: bool) void {
    self.units.define(@intCast(index), .{
        .move_speed = @floatCast(move_speed),
        .aggro_range = @floatCast(aggro_range),
        .attack_range = @floatCast(attack_range),
        .attack_point = @floatCast(attack_point),
        .attack_backswing = @floatCast(attack_backswing),
        .attack_cooldown = @floatCast(attack_cooldown),
        .turn_rate = @floatCast(turn_rate),
        .siege = siege,
        .sight_range = @floatCast(sight_range),
        .clear_vision = clear_vision,
    }) catch oom();
}

/// Lane `index`: its spawner's spot and its lane nodes (none for a camp).
pub fn setLane(self: *UnitStore, index: i64, spawn: Vector3, points: PackedVector3Array) void {
    self.units.setLane(@intCast(index), v3(spawn), readVec3(&points)) catch oom();
}

/// The map's WalkGrid: `size` cells of `cell` meters from `origin` (world XZ), 1 = walkable.
pub fn setWalkGrid(self: *UnitStore, origin: Vector2, size: Vector2i, cell: f64, cells: PackedByteArray) void {
    self.units.grid.set(self.allocator, origin.x, origin.y, @intCast(size.x), @intCast(size.y), @floatCast(cell), readBytes(&cells)) catch oom();
}

/// The navigation map the creeps' paths and corners are asked of. Asks it once from here, the
/// main thread, so the bindings are set up before worker threads use them.
pub fn setNavigationMap(self: *UnitStore, map: Rid) void {
    self.map = map;
    _ = NavigationServer3D.mapGetClosestPoint(map, .{ .x = 0, .y = 0, .z = 0 });
    var points = NavigationServer3D.mapGetPath(map, .{ .x = 0, .y = 0, .z = 0 }, .{ .x = 0, .y = 0, .z = 0 }, true, .{});
    points.deinit();
    self.units.nav = .{ .context = self, .closestPoint = navClosestPoint, .path = navPath };
}

/// How many threads answer path requests at once (at most the NavigationServer's
/// navigation/pathfinding/max_threads: more just wait for a free query slot).
pub fn setPathThreads(self: *UnitStore, threads: i64) void {
    self.units.path_threads = @intCast(std.math.clamp(threads, 1, 16));
}

/// The avoidance agent of NPC `h` (by its index: the registry reuses agents across lives).
pub fn setAgent(self: *UnitStore, h: i64, agent: Rid) void {
    if (core.handle.kindOf(h) != .npc) return;
    self.agents[core.handle.indexOf(h)] = agent;
}

fn navClosestPoint(context: *anyopaque, point: Vec3) Vec3 {
    const self: *UnitStore = @ptrCast(@alignCast(context));
    return v3(NavigationServer3D.mapGetClosestPoint(self.map, gv3(point)));
}

/// Called from several threads at once (Units.resolve).
fn navPath(context: *anyopaque, from: Vec3, to: Vec3, gpa: Allocator, out: *std.ArrayList(Vec3)) void {
    const self: *UnitStore = @ptrCast(@alignCast(context));
    var points = NavigationServer3D.mapGetPath(self.map, gv3(from), gv3(to), true, .{});
    defer points.deinit();
    out.clearRetainingCapacity();
    out.appendSlice(gpa, readVec3(&points)) catch {};
}

// --- Units coming and going ----------------------------------------------------------------

/// A new living unit; -1 when its kind's pool (512) is full.
pub fn addUnit(self: *UnitStore, kind: i64, team: i64, definition: i64, position: Vector3, yaw: f64, radius: f64,
    height: f64, scale: f64, health: f64, armor: f64, armor_type: i64) i64 {
    return self.units.create(kindOf(kind) orelse return none, .{
        .team = @intCast(team),
        .definition = @intCast(definition),
        .position = v3(position),
        .yaw = @floatCast(yaw),
        .radius = @floatCast(radius),
        .health = @floatCast(health),
        .max_health = @floatCast(health),
        .combat = .{ .armor = @floatCast(armor), .armor_type = @intCast(armor_type) },
        .look = .{ .height = @floatCast(height), .scale = @floatCast(scale) },
    }) catch oom();
}

pub fn startNpc(self: *UnitStore, h: i64, lane: i64, home: Vector3, scan_offset: f64) void {
    self.units.startNpc(h, @intCast(lane), v3(home), @floatCast(scan_offset));
}

pub fn fall(self: *UnitStore, h: i64, dying_time: f64) void {
    self.units.fall(h, @floatCast(dying_time)) catch oom();
}

pub fn rise(self: *UnitStore, h: i64, health: f64) void {
    self.units.rise(h, @floatCast(health)) catch oom();
}

pub fn release(self: *UnitStore, h: i64) void {
    self.units.release(h);
}

pub fn clearAll(self: *UnitStore) void {
    self.units.clear();
}

/// UnitRegistry.Life: 0 free (gone), 1 alive, 2 dying (an NPC), 3 dead (a fallen hero).
pub fn lifeOf(self: *UnitStore, h: i64) i64 {
    return @intFromEnum(self.units.lifeOf(h));
}

pub fn isAlive(self: *UnitStore, h: i64) bool {
    return self.units.isAlive(h);
}

// --- One unit's body -----------------------------------------------------------------------

pub fn positionOf(self: *UnitStore, h: i64) Vector3 {
    return gv3(if (self.units.body(h, "position")) |p| p.* else Vec3.zero);
}
pub fn yawOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "yaw")) |p| p.* else 0;
}
pub fn velocityOf(self: *UnitStore, h: i64) Vector3 {
    return gv3(if (self.units.body(h, "velocity")) |p| p.* else Vec3.zero);
}
pub fn radiusOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "radius")) |p| p.* else 0;
}
pub fn heightOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "look")) |p| p.height else 0;
}
pub fn scaleOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "look")) |p| p.scale else 1;
}
pub fn teamOf(self: *UnitStore, h: i64) i64 {
    return if (self.units.body(h, "team")) |p| p.* else 0;
}
pub fn definitionOf(self: *UnitStore, h: i64) i64 {
    return if (self.units.body(h, "definition")) |p| p.* else 0;
}
pub fn healthOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "health")) |p| p.* else 0;
}
pub fn maxHealthOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "max_health")) |p| p.* else 0;
}
pub fn armorOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "combat")) |p| p.armor else 0;
}
pub fn armorTypeOf(self: *UnitStore, h: i64) i64 {
    return if (self.units.body(h, "combat")) |p| p.armor_type else 0;
}
pub fn evasionOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "combat")) |p| p.evasion else 0;
}
pub fn parryOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "combat")) |p| p.parry else 0;
}
pub fn spellDamageOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "combat")) |p| p.spell_damage else 0;
}
pub fn isInvulnerable(self: *UnitStore, h: i64) bool {
    return if (self.units.body(h, "combat")) |p| p.invulnerable else false;
}
pub fn isStealthed(self: *UnitStore, h: i64) bool {
    return if (self.units.body(h, "stealthed")) |p| p.* else false;
}
pub fn sightedOf(self: *UnitStore, h: i64) i64 {
    return if (self.units.body(h, "sighted")) |p| p.* else 0;
}
pub fn highlightOf(self: *UnitStore, h: i64) i64 {
    return if (self.units.body(h, "look")) |p| p.highlight else 0;
}
pub fn flashTimeOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "look")) |p| p.flash_time else 0;
}
pub fn flashColorOf(self: *UnitStore, h: i64) Color {
    const c = if (self.units.body(h, "look")) |p| p.flash_color else [4]f32{ 1, 1, 1, 1 };
    return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
}
pub fn armorBonusOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "bonus")) |p| p.armor else 0;
}
pub fn rangedBonusOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "bonus")) |p| p.ranged else 0;
}
pub fn manaRegenBonusOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "bonus")) |p| p.mana_regen else 0;
}
/// When the unit last attacked `team` (noh GetLastAggression); -INF if never.
pub fn lastAggression(self: *UnitStore, h: i64, team: i64) f64 {
    const aggressions = self.units.body(h, "aggressions") orelse return -std.math.inf(f64);
    return aggressions[@intCast(team & 7)];
}
pub fn dyingTimeOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.body(h, "dying_time")) |p| p.* else 0;
}

pub fn setPosition(self: *UnitStore, h: i64, at: Vector3) void {
    if (self.units.body(h, "position")) |p| p.* = v3(at);
}
/// Somewhere else at once: drawn there too, not slid over from where it was.
pub fn teleport(self: *UnitStore, h: i64, at: Vector3, yaw: f64) void {
    self.units.teleport(h, v3(at), @floatCast(yaw));
}
pub fn setYaw(self: *UnitStore, h: i64, yaw: f64) void {
    if (self.units.body(h, "yaw")) |p| p.* = @floatCast(yaw);
}
pub fn setVelocity(self: *UnitStore, h: i64, velocity: Vector3) void {
    if (self.units.body(h, "velocity")) |p| p.* = v3(velocity);
}
pub fn setHealth(self: *UnitStore, h: i64, health: f64) void {
    if (self.units.body(h, "health")) |p| p.* = @floatCast(health);
}
pub fn setMaxHealth(self: *UnitStore, h: i64, health: f64) void {
    if (self.units.body(h, "max_health")) |p| p.* = @floatCast(health);
}
pub fn setCombat(self: *UnitStore, h: i64, armor: f64, evasion: f64, parry: f64, spell_damage: f64) void {
    const combat = self.units.body(h, "combat") orelse return;
    combat.armor = @floatCast(armor);
    combat.evasion = @floatCast(evasion);
    combat.parry = @floatCast(parry);
    combat.spell_damage = @floatCast(spell_damage);
}
pub fn setInvulnerable(self: *UnitStore, h: i64, value: bool) void {
    if (self.units.body(h, "combat")) |p| p.invulnerable = value;
}
pub fn setStealthed(self: *UnitStore, h: i64, value: bool) void {
    if (self.units.body(h, "stealthed")) |p| p.* = value;
}
pub fn setSighted(self: *UnitStore, h: i64, bits: i64) void {
    if (self.units.body(h, "sighted")) |p| p.* = @truncate(bits);
}
/// Highlights only go up within a frame (hover, then selection); clear_highlights() resets them.
pub fn raiseHighlight(self: *UnitStore, h: i64, level: i64) void {
    if (self.units.body(h, "look")) |p| p.highlight = @max(p.highlight, @as(u8, @intCast(level)));
}
pub fn clearHighlights(self: *UnitStore) void {
    self.units.clearHighlights();
}
pub fn flash(self: *UnitStore, h: i64, color: Color, time: f64) void {
    const look = self.units.body(h, "look") orelse return;
    look.flash_time = @floatCast(time);
    look.flash_color = .{ color.r, color.g, color.b, color.a };
}
pub fn setAggression(self: *UnitStore, h: i64, team: i64, time: f64) void {
    if (self.units.body(h, "aggressions")) |p| p[@intCast(team & 7)] = time;
}

// --- One NPC's brain -----------------------------------------------------------------------

pub fn targetOf(self: *UnitStore, h: i64) i64 {
    return if (self.units.brain(h, "target")) |p| p.* else none;
}
pub fn laneOf(self: *UnitStore, h: i64) i64 {
    return if (self.units.brain(h, "route")) |p| p.lane else -1;
}
pub fn homeOf(self: *UnitStore, h: i64) Vector3 {
    return gv3(if (self.units.brain(h, "route")) |p| p.home else Vec3.zero);
}
/// Time into its attack swing; negative when not swinging.
pub fn swingOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.brain(h, "swing")) |p| p.time else -1;
}
pub fn isAnchored(self: *UnitStore, h: i64) bool {
    return if (self.units.brain(h, "anchored")) |p| p.* else false;
}
pub fn animOf(self: *UnitStore, h: i64) i64 {
    return if (self.units.brain(h, "anim")) |p| p.* else 0;
}
pub fn aggroUntilOf(self: *UnitStore, h: i64) f64 {
    return if (self.units.brain(h, "aggro_until")) |p| p.* else 0;
}
pub fn desiredOf(self: *UnitStore, h: i64) Vector3 {
    return gv3(if (self.units.brain(h, "desired")) |p| p.* else Vec3.zero);
}

/// Sets an NPC's target; `aggro_until` > now keeps it there like an aggro pull.
pub fn setTarget(self: *UnitStore, h: i64, target: i64, aggro_until: f64) void {
    if (self.units.brain(h, "target")) |p| p.* = target;
    if (self.units.brain(h, "aggro_until")) |p| p.* = aggro_until;
}
/// -1: it stands still from now on.
pub fn setLaneOf(self: *UnitStore, h: i64, lane: i64) void {
    if (self.units.brain(h, "route")) |p| p.lane = @intCast(lane);
}
/// From its spell effects: stunned, and the shares of its move and attack speed slowed away (0..1).
pub fn setStatus(self: *UnitStore, h: i64, stunned: bool, slow: f64, attack_slow: f64) void {
    const status = self.units.brain(h, "status") orelse return;
    status.* = .{ .stunned = stunned, .slow = @floatCast(slow), .attack_slow = @floatCast(attack_slow) };
    if (stunned) {
        if (self.units.brain(h, "swing")) |swing| swing.time = -1; // a stun cuts the swing short
    }
}
/// An avoidance agent's answer: the velocity NPC `h` can move at without bumping into others.
/// The callable's arguments come in that order (NavigationServer3D.agent_set_avoidance_callback).
pub fn avoided(self: *UnitStore, velocity: Vector3, h: i64) void {
    if (self.units.brain(h, "safe_velocity")) |p| p.* = v3(velocity);
}
pub fn setListening(self: *UnitStore, h: i64, other: i64) void {
    if (self.units.brain(h, "listening")) |p| p.* = other;
}
pub fn setAnim(self: *UnitStore, h: i64, anim: i64) void {
    if (self.units.brain(h, "anim")) |p| p.* = @intCast(anim);
}

// --- Queries -------------------------------------------------------------------------------

/// Living units of `kind`, of `team` (or every team with -1).
pub fn countAlive(self: *UnitStore, kind: i64, team: i64) i64 {
    const k = kindOf(kind) orelse return 0;
    return @intCast(self.units.countAlive(k, if (team < 0) null else @intCast(team)));
}

/// Handles of one kind's living (or fallen) units, in the order the columns come in.
pub fn handles(self: *UnitStore, kind: i64, fallen: bool) PackedInt64Array {
    var list: std.ArrayList(i64) = .empty;
    defer list.deinit(self.allocator);
    if (kindOf(kind)) |k| switch (k) {
        inline else => |known| self.units.handlesOf(known, if (fallen) .fallen else .alive, &list) catch oom(),
    };
    return int64Array(list.items);
}

pub fn npcsOf(self: *UnitStore, lane: i64) PackedInt64Array {
    var list: std.ArrayList(i64) = .empty;
    defer list.deinit(self.allocator);
    self.units.npcsOf(@intCast(lane), &list) catch oom();
    return int64Array(list.items);
}

pub fn queryRadius(self: *UnitStore, center: Vector3, radius: f64) PackedInt64Array {
    var list: std.ArrayList(i64) = .empty;
    defer list.deinit(self.allocator);
    self.units.queryRadius(v3(center), @floatCast(radius), &list) catch oom();
    return int64Array(list.items);
}

pub fn findEnemy(self: *UnitStore, h: i64, scan_range: f64) i64 {
    return self.units.findEnemy(h, @floatCast(scan_range));
}

pub fn edgeDistance(self: *UnitStore, a: i64, b: i64) f64 {
    return self.units.edgeDistance(a, b);
}

pub fn sees(self: *UnitStore, team: i64, h: i64) bool {
    return self.units.sees(@intCast(team), h);
}

/// What the NPC would target right now (noh threat), or -1.
pub fn bestTarget(self: *UnitStore, h: i64) i64 {
    return self.units.bestTargetOf(h);
}

// --- Aggro ---------------------------------------------------------------------------------

pub fn attackOrderAggro(self: *UnitStore, attacker: i64, target: i64) void {
    self.units.attackOrderAggro(attacker, target);
}

pub fn npcDamaged(self: *UnitStore, victim: i64, source: i64) void {
    self.units.npcDamaged(victim, source);
}

pub fn forceAttack(self: *UnitStore, victim: i64, attacker: i64, seconds: f64) void {
    self.units.forceAttack(victim, attacker, seconds);
}

// --- Auras ---------------------------------------------------------------------------------

pub fn clearAuras(self: *UnitStore) void {
    self.units.clearAuras();
}

/// `stat`: AuraAbility.Stat (0 armor, 1 ranged damage percent, 2 mana regen).
pub fn applyAura(self: *UnitStore, team: i64, center: Vector3, radius: f64, stat: i64, amount: f64) void {
    self.units.applyAura(@intCast(team), v3(center), @floatCast(radius), @enumFromInt(stat), @floatCast(amount));
}

// --- Sight -------------------------------------------------------------------------------

/// The fog of war's grid: `size` cells of `cell` meters from `origin` (world XZ), padded by `pad`
/// cells on every side (FogOfWar._layout). Drops the team maps.
pub fn setSightLayout(self: *UnitStore, origin: Vector2, size: Vector2i, cell: f64, pad: i64) void {
    self.units.sight.setLayout(self.allocator, origin.x, origin.y, @floatCast(cell), @intCast(size.x), @intCast(size.y), @intCast(pad));
}

/// Per padded cell: the top of what blocks sight there, and the ground at its center.
pub fn setSightOcclusion(self: *UnitStore, heights: PackedFloat32Array, ground: PackedFloat32Array) void {
    self.units.sight.setOcclusion(self.allocator, readFloats(&heights), readFloats(&ground)) catch oom();
}

/// Casts every unit's sight into its team's map (eyes `eye_height` above the ground); the new
/// maps replace the last ones.
pub fn updateFog(self: *UnitStore, eye_height: f64, player_team: i64) void {
    self.units.updateFog(@floatCast(eye_height), @intCast(player_team)) catch oom();
}

/// A copy of a team's last finished map; empty if it has none.
pub fn sightMap(self: *UnitStore, team: i64) PackedByteArray {
    var out = PackedByteArray.init();
    if (team < 0 or team >= core.units.max_teams) return out;
    const map = self.units.sight.maps[@intCast(team)];
    if (map.len == 0) return out;
    _ = out.resize(@intCast(map.len));
    const target: [*]u8 = @ptrCast(raw.packedByteArrayOperatorIndex(out.ptr(), 0).?);
    @memcpy(target[0..map.len], map);
    return out;
}

/// One unit's sight bits from the current maps; -1 (everyone) without fog of war.
pub fn sightBitsOf(self: *UnitStore, h: i64, enabled: bool, aggression_time: f64) i64 {
    return self.units.sightBitsOf(h, enabled, aggression_time);
}

/// Every unit's sight bits from the maps; `enabled` false: everyone sees everyone.
pub fn updateSight(self: *UnitStore, enabled: bool, aggression_time: f64) void {
    self.units.updateSight(enabled, aggression_time);
}

// --- The tick ------------------------------------------------------------------------------

/// One tick of the creeps (see the top of this file).
pub fn step(self: *UnitStore, delta: f64) void {
    if (!isValid(self.map)) self.units.nav = null;
    const waiting = Time.getTicksUsec();
    self.units.collect();
    const started = Time.getTicksUsec();
    self.units.tick(@floatCast(delta)) catch oom();
    const ticked = Time.getTicksUsec();
    self.units.resolve() catch oom();
    const resolved = Time.getTicksUsec();
    self.units.finish(@floatCast(delta));
    const finished = Time.getTicksUsec();
    const npc = self.units.npcs.alive.slice();
    for (npc.items(.index), npc.items(.position), npc.items(.desired), npc.items(.anchored)) |index, position, desired, anchored| {
        const agent = self.agents[index];
        if (!isValid(agent)) continue;
        NavigationServer3D.agentSetPosition(agent, gv3(position));
        NavigationServer3D.agentSetVelocity(agent, gv3(desired));
        NavigationServer3D.agentSetAvoidancePriority(agent, if (anchored) 1.0 else 0.5); // standing fighters don't move for anyone
    }
    self.profile = .{ @floatFromInt(started - waiting), @floatFromInt(ticked - started), @floatFromInt(resolved - ticked),
        @floatFromInt(finished - resolved), @floatFromInt(Time.getTicksUsec() - finished), @floatFromInt(self.units.flight.requests.items.len) };
}

/// The last step, for profiling: microseconds spent waiting for last tick's paths, in its tick,
/// asking for corners and starting the path threads, in its finish and on the avoidance agents;
/// then how many paths it asked for.
pub fn stepProfile(self: *UnitStore) PackedFloat32Array {
    var out = PackedFloat32Array.init();
    _ = out.resize(self.profile.len);
    const target: [*]f32 = @ptrCast(@alignCast(raw.packedFloat32ArrayOperatorIndex(out.ptr(), 0).?));
    @memcpy(target[0..self.profile.len], &self.profile);
    return out;
}

pub fn buried(self: *UnitStore) PackedInt64Array {
    return int64Array(self.units.buried.items);
}
pub fn landedSources(self: *UnitStore) PackedInt64Array {
    return int64Array(self.units.landed_sources.items);
}
pub fn landedTargets(self: *UnitStore) PackedInt64Array {
    return int64Array(self.units.landed_targets.items);
}

// --- Bulk columns --------------------------------------------------------------------------
// One field of a kind's living (or fallen) rows. Names: the row field, or a field inside one
// ("look.height"); fields only NPCs have read as defaults for other kinds.

const vec3_names = .{ "position", "velocity", "desired", "safe_velocity", "route.waypoint", "route.home" };
const float_names = .{ "yaw", "radius", "health", "max_health", "dying_time", "look.height", "look.scale",
    "look.flash_time", "swing.time", "bonus.mana_regen", "status.slow" };
const int_names = .{ "team", "definition", "sighted", "stealthed", "look.highlight", "target", "anim", "route.lane",
    "anchored", "combat.invulnerable", "status.stunned" };

pub fn vec3Column(self: *UnitStore, kind: i64, fallen: bool, name: String) PackedVector3Array {
    var buffer: [64]u8 = undefined;
    const wanted = name.toLatin1Buf(&buffer);
    var out = PackedVector3Array.init();
    inline for (vec3_names) |column| {
        if (std.mem.eql(u8, wanted, column)) {
            const n = self.count(kind, fallen);
            if (n == 0) return out;
            _ = out.resize(@intCast(n));
            const target: [*]Vec3 = @ptrCast(@alignCast(raw.packedVector3ArrayOperatorIndex(out.ptr(), 0).?));
            self.fill(Vec3, kind, fallen, column, target[0..n]);
        }
    }
    return out;
}

pub fn floatColumn(self: *UnitStore, kind: i64, fallen: bool, name: String) PackedFloat32Array {
    var buffer: [64]u8 = undefined;
    const wanted = name.toLatin1Buf(&buffer);
    var out = PackedFloat32Array.init();
    inline for (float_names) |column| {
        if (std.mem.eql(u8, wanted, column)) {
            const n = self.count(kind, fallen);
            if (n == 0) return out;
            _ = out.resize(@intCast(n));
            const target: [*]f32 = @ptrCast(@alignCast(raw.packedFloat32ArrayOperatorIndex(out.ptr(), 0).?));
            self.fill(f32, kind, fallen, column, target[0..n]);
        }
    }
    return out;
}

pub fn intColumn(self: *UnitStore, kind: i64, fallen: bool, name: String) PackedInt64Array {
    var buffer: [64]u8 = undefined;
    const wanted = name.toLatin1Buf(&buffer);
    var out = PackedInt64Array.init();
    inline for (int_names) |column| {
        if (std.mem.eql(u8, wanted, column)) {
            const n = self.count(kind, fallen);
            if (n == 0) return out;
            _ = out.resize(@intCast(n));
            const target: [*]i64 = @ptrCast(@alignCast(raw.packedInt64ArrayOperatorIndex(out.ptr(), 0).?));
            self.fill(i64, kind, fallen, column, target[0..n]);
        }
    }
    return out;
}

/// The flash colors of a kind's living rows.
pub fn colorColumn(self: *UnitStore, kind: i64, fallen: bool) PackedColorArray {
    var out = PackedColorArray.init();
    const n = self.count(kind, fallen);
    if (n == 0) return out;
    _ = out.resize(@intCast(n));
    const target: [*][4]f32 = @ptrCast(@alignCast(raw.packedColorArrayOperatorIndex(out.ptr(), 0).?));
    switch (kindOf(kind).?) {
        inline else => |k| for (self.units.storeOf(k).rows(if (fallen) .fallen else .alive).items(.look), 0..) |look, i| {
            target[i] = look.flash_color;
        },
    }
    return out;
}

/// Where to draw a kind's rows `alpha` (0-1) of the way to the next tick (Simulation.alpha):
/// NPCs between their last two ticks; heroes and summons where their bodies are.
pub fn displayPositions(self: *UnitStore, kind: i64, fallen: bool, alpha: f64) PackedVector3Array {
    var out = PackedVector3Array.init();
    const n = self.count(kind, fallen);
    if (n == 0) return out;
    _ = out.resize(@intCast(n));
    const target: [*]Vec3 = @ptrCast(@alignCast(raw.packedVector3ArrayOperatorIndex(out.ptr(), 0).?));
    const t: f32 = @floatCast(std.math.clamp(alpha, 0, 1));
    switch (kindOf(kind).?) {
        .npc => {
            const rows = self.units.npcs.rows(if (fallen) .fallen else .alive).slice();
            for (rows.items(.look), rows.items(.position), target[0..n]) |look, position, *slot| slot.* = core.Units.displayPosition(look, position, t);
        },
        inline else => |k| @memcpy(target[0..n], self.units.storeOf(k).rows(if (fallen) .fallen else .alive).items(.position)),
    }
    return out;
}

pub fn displayYaws(self: *UnitStore, kind: i64, fallen: bool, alpha: f64) PackedFloat32Array {
    var out = PackedFloat32Array.init();
    const n = self.count(kind, fallen);
    if (n == 0) return out;
    _ = out.resize(@intCast(n));
    const target: [*]f32 = @ptrCast(@alignCast(raw.packedFloat32ArrayOperatorIndex(out.ptr(), 0).?));
    const t: f32 = @floatCast(std.math.clamp(alpha, 0, 1));
    switch (kindOf(kind).?) {
        .npc => {
            const rows = self.units.npcs.rows(if (fallen) .fallen else .alive).slice();
            for (rows.items(.look), rows.items(.yaw), target[0..n]) |look, yaw, *slot| slot.* = core.Units.displayYaw(look, yaw, t);
        },
        inline else => |k| @memcpy(target[0..n], self.units.storeOf(k).rows(if (fallen) .fallen else .alive).items(.yaw)),
    }
    return out;
}

fn count(self: *UnitStore, kind: i64, fallen: bool) usize {
    const k = kindOf(kind) orelse return 0;
    switch (k) {
        inline else => |known| return self.units.storeOf(known).rows(if (fallen) .fallen else .alive).len,
    }
}

/// Copies column `path` ("field" or "field.inner") of a kind's rows into `out`, converted to T.
fn fill(self: *UnitStore, comptime T: type, kind: i64, fallen: bool, comptime path: []const u8, out: []T) void {
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    const field = comptime if (dot) |d| path[0..d] else path;
    switch (kindOf(kind).?) {
        inline else => |k| {
            const Row = core.units.RowOf(k);
            if (comptime !@hasField(Row, field)) {
                @memset(out, defaultOf(T));
                return;
            }
            const S = core.store.Store(Row);
            const values = self.units.storeOf(k).rows(if (fallen) .fallen else .alive).items(@field(S.Field, field));
            for (values, out) |value, *slot| {
                const inner = if (dot) |d| @field(value, path[d + 1 ..]) else value;
                slot.* = convert(T, inner);
            }
        },
    }
}

fn defaultOf(comptime T: type) T {
    return switch (T) {
        Vec3 => Vec3.zero,
        f32 => 0,
        i64 => 0,
        else => @compileError("no default"),
    };
}

fn convert(comptime T: type, value: anytype) T {
    const V = @TypeOf(value);
    if (T == V) return value;
    return switch (@typeInfo(V)) {
        .bool => if (T == i64) @intFromBool(value) else @compileError("bool to " ++ @typeName(T)),
        .int => if (T == i64) @intCast(value) else @floatFromInt(value),
        .float => @floatCast(value),
        else => @compileError("can't convert " ++ @typeName(V)),
    };
}

// --- Saving --------------------------------------------------------------------------------

/// Every unit as bytes (the stores' arrays, column by column), with the clock.
pub fn save(self: *UnitStore) PackedByteArray {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(self.allocator);
    self.units.save(&bytes) catch oom();
    var out = PackedByteArray.init();
    if (bytes.items.len == 0) return out;
    _ = out.resize(@intCast(bytes.items.len));
    const target: [*]u8 = @ptrCast(raw.packedByteArrayOperatorIndex(out.ptr(), 0).?);
    @memcpy(target[0..bytes.items.len], bytes.items);
    return out;
}

/// False when the bytes don't fit this build's rows (a save from another layout).
pub fn load(self: *UnitStore, bytes: PackedByteArray) bool {
    return self.units.load(readBytes(&bytes)) catch oom();
}

/// Game time of the simulation.
pub fn now(self: *UnitStore) f64 {
    return self.units.clock;
}

pub fn setClock(self: *UnitStore, clock: f64) void {
    self.units.clock = clock;
}

// --- Marshaling ----------------------------------------------------------------------------

const none: i64 = core.handle.none;

fn kindOf(kind: i64) ?Kind {
    return switch (kind) {
        0 => .hero,
        1 => .npc,
        2 => .summon,
        else => null,
    };
}

fn v3(v: Vector3) Vec3 {
    return .{ .x = v.x, .y = v.y, .z = v.z };
}

fn gv3(v: Vec3) Vector3 {
    return .{ .x = v.x, .y = v.y, .z = v.z };
}

fn isValid(rid: Rid) bool {
    return !std.mem.allEqual(u8, std.mem.asBytes(&rid), 0);
}

fn oom() noreturn {
    @panic("out of memory");
}

// gdzig's index()/indexConst() on packed arrays miss an @alignCast for 4-byte elements and don't
// compile on Zig 0.17, so the arrays' memory is reached through the C operators.

fn readVec3(points: *const PackedVector3Array) []const Vec3 {
    const n: usize = @intCast(points.size());
    if (n == 0) return &.{};
    const first: [*]const Vec3 = @ptrCast(@alignCast(raw.packedVector3ArrayOperatorIndexConst(points.constPtr(), 0).?));
    return first[0..n];
}

fn readFloats(values: *const PackedFloat32Array) []const f32 {
    const n: usize = @intCast(values.size());
    if (n == 0) return &.{};
    const first: [*]const f32 = @ptrCast(@alignCast(raw.packedFloat32ArrayOperatorIndexConst(values.constPtr(), 0).?));
    return first[0..n];
}

fn readBytes(bytes: *const PackedByteArray) []const u8 {
    const n: usize = @intCast(bytes.size());
    if (n == 0) return &.{};
    const first: [*]const u8 = @ptrCast(raw.packedByteArrayOperatorIndexConst(bytes.constPtr(), 0).?);
    return first[0..n];
}

fn int64Array(values: []const i64) PackedInt64Array {
    var out = PackedInt64Array.init();
    if (values.len == 0) return out;
    _ = out.resize(@intCast(values.len));
    const target: [*]i64 = @ptrCast(@alignCast(raw.packedInt64ArrayOperatorIndex(out.ptr(), 0).?));
    @memcpy(target[0..values.len], values);
    return out;
}

fn vec3Array(values: []const Vec3) PackedVector3Array {
    var out = PackedVector3Array.init();
    if (values.len == 0) return out;
    _ = out.resize(@intCast(values.len));
    const target: [*]Vec3 = @ptrCast(@alignCast(raw.packedVector3ArrayOperatorIndex(out.ptr(), 0).?));
    @memcpy(target[0..values.len], values);
    return out;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const Kind = core.Kind;
const Vec3 = core.Vec3;
const godot = @import("godot");
const raw = &godot.raw;
const Registry = godot.extension.Registry;
const Node = godot.class.Node;
const Object = godot.class.Object;
const String = godot.builtin.String;
const Vector2 = godot.builtin.Vector2;
const Vector2i = godot.builtin.Vector2i;
const Vector3 = godot.builtin.Vector3;
const Color = godot.builtin.Color;
const PackedByteArray = godot.builtin.PackedByteArray;
const PackedInt64Array = godot.builtin.PackedInt64Array;
const PackedFloat32Array = godot.builtin.PackedFloat32Array;
const PackedVector3Array = godot.builtin.PackedVector3Array;
const Rid = godot.builtin.Rid;
const NavigationServer3D = godot.class.NavigationServer3d;
const Time = godot.class.Time;
const PackedColorArray = godot.builtin.PackedColorArray;
