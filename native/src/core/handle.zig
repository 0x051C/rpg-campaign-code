//! Unit handles: which pool a unit lives in, its place there, and which life of that place.
//!
//!     handle = generation << 12 | kind << 9 | index        (index < 512, kind < 8)
//!
//! The shape of a handle says its kind, so code goes straight to that kind's store: heroes are
//! handles 0-511 of every generation, NPCs 512-1023, summons 1024-1535. The generation goes up
//! each time an index is reused, so a handle to a unit that's gone stops resolving.

pub const Kind = enum(u3) {
    hero = 0,
    npc = 1,
    summon = 2,
};

pub const kinds = [_]Kind{ .hero, .npc, .summon };

pub const index_bits = 9;
pub const kind_bits = 3;
pub const per_kind = 1 << index_bits; // 512
pub const generation_shift = index_bits + kind_bits; // 12

/// No unit (GDScript's UnitRegistry.NONE).
pub const none: i64 = -1;

pub fn make(kind: Kind, index: u16, generation: u32) i64 {
    return (@as(i64, generation) << generation_shift) | (@as(i64, @intFromEnum(kind)) << index_bits) | index;
}

/// The kind a handle's shape says, or null for none and for kind bits no store uses.
pub fn kindOf(handle: i64) ?Kind {
    if (handle < 0) return null;
    const bits: u3 = @intCast((handle >> index_bits) & ((1 << kind_bits) - 1));
    return switch (bits) {
        0 => .hero,
        1 => .npc,
        2 => .summon,
        else => null,
    };
}

pub fn indexOf(handle: i64) u16 {
    return @intCast(handle & (per_kind - 1));
}

pub fn generationOf(handle: i64) u32 {
    return @intCast(handle >> generation_shift);
}

const std = @import("std");

test "a handle's shape says its kind" {
    const h = make(.npc, 37, 5);
    try std.testing.expectEqual(Kind.npc, kindOf(h).?);
    try std.testing.expectEqual(@as(u16, 37), indexOf(h));
    try std.testing.expectEqual(@as(u32, 5), generationOf(h));
    try std.testing.expect(make(.hero, 511, 0) < 512);
    try std.testing.expect(make(.npc, 0, 0) == 512);
    try std.testing.expect(make(.summon, 0, 0) == 1024);
    try std.testing.expectEqual(@as(?Kind, null), kindOf(none));
}
