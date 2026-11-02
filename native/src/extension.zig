//! The extension's classes, registered when Godot loads bin/libunits.so (units.gdextension).

pub fn register(r: *Registry) void {
    r.addModule(UnitStore);
}

pub fn unregister(r: *Registry) void {
    r.removeModule(UnitStore);
}

const godot = @import("godot");
const Registry = godot.extension.Registry;
const UnitStore = @import("UnitStore.zig");
