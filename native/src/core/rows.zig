//! What each kind of unit keeps, as row structs: every field becomes its own array in the kind's
//! store. Every kind has a Body (where it is, its health, what the fog of war and the combat rules
//! read); only NPCs have a Brain (lane, target, swing, path: the creep behavior in units.zig).
//! Heroes and summons think in their Unit nodes, so their rows are just a body.
//!
//! Hot fields, read by the per-tick loops, are columns of their own. Cold ones that are always
//! read together (the combat stats a hit needs, how a unit is drawn) share one small struct per
//! column. That also keeps a row under the ~30 fields std.MultiArrayList sorts at compile time.

pub const Body = struct {
    /// The row's own index (the low bits of its handle), for the store's table.
    index: u16 = 0,
    team: u8 = 0,
    /// Index into the definitions table (UnitRegistry.definitions).
    definition: u16 = 0,
    position: Vec3 = .{},
    yaw: f32 = 0,
    velocity: Vec3 = .{},
    radius: f32 = 0.5,
    health: f32 = 0,
    max_health: f32 = 0,
    /// Bit `team` set: that team sees the unit (noh VIS_SIGHTED). All bits: no fog of war.
    sighted: i32 = -1,
    stealthed: bool = false,
    combat: Combat = .{},
    bonus: Bonus = .{},
    look: Look = .{},
    /// When it last attacked each team (noh GetLastAggression); -inf: never.
    aggressions: [8]f64 = @splat(-std.math.inf(f64)),
    /// Fallen NPCs: what's left of the death animation before the body becomes a corpse.
    dying_time: f32 = 0,
};

/// What the damage rules read, hit by hit (cold: one array of these, not one per field).
pub const Combat = struct {
    /// Flat, before aura bonuses; heroes' come from their stats.
    armor: f32 = 0,
    armor_type: u8 = 0,
    /// Percent chances to dodge and to parry an attack.
    evasion: f32 = 0,
    parry: f32 = 0,
    /// Percent more damage its spells deal.
    spell_damage: f32 = 0,
    invulnerable: bool = false,
};

/// Aura bonuses, recomputed every AURA_UPDATE_TIME.
pub const Bonus = struct {
    armor: f32 = 0,
    /// Fraction of base damage.
    ranged: f32 = 0,
    mana_regen: f32 = 0,
};

/// How it's drawn and picked.
pub const Look = struct {
    height: f32 = 2.4,
    /// Model size; maps can shrink their creeps.
    scale: f32 = 1,
    highlight: u8 = 0,
    flash_time: f32 = 0,
    flash_color: [4]f32 = .{ 1, 1, 1, 1 },
    /// Where it was when the last tick started: frames between ticks draw it in between.
    previous: Vec3 = .{},
    previous_yaw: f32 = 0,
};

/// noh's creep behavior (ICreepEntity::ServerFrameThink), per NPC.
pub const Brain = struct {
    route: Route = .{},
    target: i64 = handle.none,
    /// A pulled creep keeps its target until then (noh primary target).
    aggro_until: f64 = 0,
    timers: Timers = .{},
    swing: Swing = .{},
    /// Standing (attacking, at home, stunned): others route around it.
    anchored: bool = false,
    path: PathState = .{},
    /// The avoidance velocity the NavigationServer worked out for it.
    safe_velocity: Vec3 = .{},
    /// The velocity it asks the NavigationServer for.
    desired: Vec3 = .{},
    /// From its spell effects (UnitRegistry keeps them).
    status: Status = .{},
    /// Who it turns toward (a villager being talked to).
    listening: i64 = handle.none,
    /// The animation its model plays (UnitRegistry.Anim); 0 restarts the clip.
    anim: u8 = 0,
};

pub const Route = struct {
    /// Index into the lanes; -1: stands still (a villager).
    lane: i16 = -1,
    waypoint: Vec3 = Vec3.inf,
    /// Where an NPC without lane nodes (a camp creature) goes back to: its own spot.
    home: Vec3 = .{},
};

pub const Timers = struct {
    cooldown: f32 = 0,
    scan: f32 = 0,
    repath: f32 = 0,
};

pub const Swing = struct {
    /// Time into the attack swing; negative when not swinging.
    time: f32 = -1,
    landed: bool = false,
};

pub const PathState = struct {
    /// Where its current path leads; inf: none yet.
    goal: Vec3 = Vec3.inf,
    index: u16 = 0,
    /// It wants to walk this tick: the second half of the tick follows its path.
    seeking: bool = false,
};

pub const Status = struct {
    stunned: bool = false,
    slow: f32 = 0,
    /// Share of its attack speed taken away (a chill): swings and cooldowns run that much slower.
    attack_slow: f32 = 0,
};

pub const HeroRow = Body;
pub const SummonRow = Body;
pub const NpcRow = Merge(Body, Brain);

/// What the creep behavior needs to know about a unit type (UnitDefinition).
pub const Def = struct {
    move_speed: f32 = 4.5,
    aggro_range: f32 = 8,
    attack_range: f32 = 1.2,
    attack_point: f32 = 0.35,
    attack_backswing: f32 = 0.35,
    attack_cooldown: f32 = 1.2,
    turn_rate: f32 = 12,
    siege: bool = false,
    /// Meters it sees (0: nothing, like neutrals); clear vision sees over cliffs and trees.
    sight_range: f32 = 0,
    clear_vision: bool = false,
};

/// One struct with the fields of both, in order: a kind's row from shared parts.
pub fn Merge(comptime A: type, comptime B: type) type {
    const a = @typeInfo(A).@"struct";
    const b = @typeInfo(B).@"struct";
    return @Struct(.auto, null, a.field_names ++ b.field_names, a.field_types ++ b.field_types, a.field_attrs ++ b.field_attrs);
}

const std = @import("std");
const handle = @import("handle.zig");
const Vec3 = @import("vec.zig").Vec3;
