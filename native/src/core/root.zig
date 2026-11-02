//! The unit registry's core: plain Zig, no Godot, tested with `zig build test`.

pub const handle = @import("handle.zig");
pub const vec = @import("vec.zig");
pub const rows = @import("rows.zig");
pub const store = @import("store.zig");
pub const grid = @import("grid.zig");
pub const lane = @import("lane.zig");
pub const sight = @import("sight.zig");
pub const units = @import("units.zig");

pub const Units = units.Units;
pub const Kind = handle.Kind;
pub const Vec3 = vec.Vec3;

test {
    _ = handle;
    _ = vec;
    _ = store;
    _ = grid;
    _ = lane;
    _ = sight;
    _ = units;
}
