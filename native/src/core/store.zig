//! One kind's units as structures of arrays: the living ones packed together in `alive`, the
//! fallen ones (dying, or a dead hero waiting to be revived) in `fallen`. Each list is a
//! std.MultiArrayList, one array per field of `Row`, so a loop over one field reads only that
//! field's memory and never steps over a dead row.
//!
//! A unit's index (the low bits of its handle) stays the same for its whole life while its row
//! moves: when it dies it leaves `alive` (the last living row fills its place) and joins
//! `fallen`. The `slots` table says where each index's row is now, and which generation owns it.
//! `Row` needs an `index: u16` field: the row's own index, to fix the table after a move.

pub const List = enum(u2) { free, alive, fallen };

pub const Slot = struct {
    generation: u32 = 0,
    list: List = .free,
    row: u32 = 0,
};

pub fn Store(comptime RowType: type) type {
    return struct {
        const Self = @This();
        pub const Row = RowType;
        pub const Field = std.meta.FieldEnum(Row);
        pub const Rows = std.MultiArrayList(Row);

        alive: Rows = .empty,
        fallen: Rows = .empty,
        slots: [handle.per_kind]Slot = @splat(.{}),
        /// Free indices, the next one last.
        free: [handle.per_kind]u16 = undefined,
        free_count: u16 = 0,

        pub fn init() Self {
            var self: Self = .{};
            self.resetFree();
            return self;
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.alive.deinit(gpa);
            self.fallen.deinit(gpa);
        }

        fn resetFree(self: *Self) void {
            self.free_count = 0;
            var index: usize = handle.per_kind;
            while (index > 0) {
                index -= 1;
                if (self.slots[index].list == .free) {
                    self.free[self.free_count] = @intCast(index);
                    self.free_count += 1;
                }
            }
        }

        /// A new living row; null when every index is taken.
        pub fn create(self: *Self, gpa: Allocator, kind: handle.Kind, row: Row) !?i64 {
            if (self.free_count == 0) return null;
            self.free_count -= 1;
            const index = self.free[self.free_count];
            var placed = row;
            placed.index = index;
            try self.alive.append(gpa, placed);
            self.slots[index].list = .alive;
            self.slots[index].row = @intCast(self.alive.len - 1);
            return handle.make(kind, index, self.slots[index].generation);
        }

        /// Where a handle's row is, or null when the handle is stale or free.
        pub fn find(self: *const Self, h: i64) ?Slot {
            const index = handle.indexOf(h);
            const slot = self.slots[index];
            if (slot.list == .free or slot.generation != handle.generationOf(h)) return null;
            return slot;
        }

        pub fn rows(self: *Self, list: List) *Rows {
            return if (list == .fallen) &self.fallen else &self.alive;
        }

        /// Moves an index's row from one list to the other (death, or a hero's revival).
        pub fn move(self: *Self, gpa: Allocator, index: u16, to: List) !void {
            const slot = self.slots[index];
            if (slot.list == .free or slot.list == to) return;
            const row = self.rows(slot.list).get(slot.row);
            self.removeRow(slot.list, slot.row);
            const destination = self.rows(to);
            try destination.append(gpa, row);
            self.slots[index].list = to;
            self.slots[index].row = @intCast(destination.len - 1);
        }

        /// The index is free again; handles to it stop resolving.
        pub fn release(self: *Self, index: u16) void {
            const slot = self.slots[index];
            if (slot.list == .free) return;
            self.removeRow(slot.list, slot.row);
            self.slots[index] = .{ .generation = slot.generation +% 1, .list = .free };
            self.free[self.free_count] = index;
            self.free_count += 1;
        }

        /// Takes a row out of its list: the list's last row moves into its place.
        fn removeRow(self: *Self, list: List, row: u32) void {
            const rows_ = self.rows(list);
            const last: u32 = @intCast(rows_.len - 1);
            if (row != last) {
                const moved = rows_.items(.index)[last];
                self.slots[moved].row = row;
            }
            rows_.swapRemove(row);
        }

        /// Every row gone; generations go on, so old handles stay dead.
        pub fn clear(self: *Self) void {
            self.alive.clearRetainingCapacity();
            self.fallen.clearRetainingCapacity();
            for (&self.slots) |*slot| {
                if (slot.list != .free) slot.generation +%= 1;
                slot.list = .free;
            }
            self.resetFree();
        }

        // --- Saving: the table and both lists, column by column ---------------------------
        //
        // A save names its columns (field name and element size), so it still loads after the rows
        // change: columns are matched by name, and one that's gone or changed size is left at its
        // defaults (a new or changed field), instead of the whole save being refused.

        /// Marks the column-named format ("UNITCOL1").
        pub const save_magic: u64 = 0x314c4f4354494e55;

        pub fn save(self: *Self, gpa: Allocator, out: *std.ArrayList(u8)) !void {
            const info = @typeInfo(Row).@"struct";
            try appendInt(gpa, out, u64, save_magic);
            try appendInt(gpa, out, u32, @sizeOf(@TypeOf(self.slots)));
            try out.appendSlice(gpa, std.mem.sliceAsBytes(&self.slots));
            try appendInt(gpa, out, u32, info.field_names.len);
            inline for (info.field_names, info.field_types) |name, T| {
                try appendInt(gpa, out, u16, name.len);
                try out.appendSlice(gpa, name);
                try appendInt(gpa, out, u32, @sizeOf(T));
            }
            for ([_]*Rows{ &self.alive, &self.fallen }) |list| {
                try appendInt(gpa, out, u32, @intCast(list.len));
                inline for (comptime info.field_names) |name| {
                    try out.appendSlice(gpa, std.mem.sliceAsBytes(list.items(@field(Field, name))));
                }
            }
        }

        /// Replaces everything with a saved store; false when the bytes aren't a store save.
        pub fn load(self: *Self, gpa: Allocator, bytes: []const u8) !bool {
            var reader: Reader = .{ .bytes = bytes };
            if ((reader.int(u64) orelse return false) != save_magic) return false;
            const table_size = reader.int(u32) orelse return false;
            if (table_size != @sizeOf(@TypeOf(self.slots))) return false;
            const table = reader.take(table_size) orelse return false;
            @memcpy(std.mem.sliceAsBytes(&self.slots), table);
            // The saved columns: name and element size
            const SavedColumn = struct { name: []const u8, size: u32 };
            const field_count = reader.int(u32) orelse return false;
            const columns = try gpa.alloc(SavedColumn, field_count);
            defer gpa.free(columns);
            for (columns) |*column| {
                const name_length = reader.int(u16) orelse return false;
                column.name = reader.take(name_length) orelse return false;
                column.size = reader.int(u32) orelse return false;
            }
            for ([_]*Rows{ &self.alive, &self.fallen }) |list| {
                const count = reader.int(u32) orelse return false;
                list.clearRetainingCapacity();
                try list.ensureTotalCapacity(gpa, count);
                for (0..count) |_| list.appendAssumeCapacity(.{});
                for (columns) |column| {
                    const data = reader.take(@as(usize, column.size) * count) orelse return false;
                    inline for (comptime @typeInfo(Row).@"struct".field_names) |name| {
                        const target = list.items(@field(Field, name));
                        if (std.mem.eql(u8, column.name, name) and column.size == @sizeOf(@TypeOf(target[0]))) {
                            @memcpy(std.mem.sliceAsBytes(target), data);
                        }
                    }
                }
            }
            self.resetFree();
            return true;
        }
    };
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Reader, count: usize) ?[]const u8 {
        if (self.at + count > self.bytes.len) return null;
        defer self.at += count;
        return self.bytes[self.at .. self.at + count];
    }

    fn int(self: *Reader, comptime T: type) ?T {
        const bytes = self.take(@sizeOf(T)) orelse return null;
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }
};

const std = @import("std");
const Allocator = std.mem.Allocator;
const handle = @import("handle.zig");

test "rows move between alive and fallen, handles keep pointing at them" {
    const gpa = std.testing.allocator;
    const Row = struct { index: u16 = 0, health: f32 = 0 };
    var store = Store(Row).init();
    defer store.deinit(gpa);
    const a = (try store.create(gpa, .npc, .{ .health = 1 })).?;
    const b = (try store.create(gpa, .npc, .{ .health = 2 })).?;
    const c = (try store.create(gpa, .npc, .{ .health = 3 })).?;
    try std.testing.expectEqual(handle.Kind.npc, handle.kindOf(a).?);

    // a dies: c fills its place among the living
    try store.move(gpa, handle.indexOf(a), .fallen);
    try std.testing.expectEqual(@as(usize, 2), store.alive.len);
    try std.testing.expectEqual(@as(f32, 3), store.alive.items(.health)[store.find(c).?.row]);
    try std.testing.expectEqual(List.fallen, store.find(a).?.list);
    try std.testing.expectEqual(@as(f32, 1), store.fallen.items(.health)[store.find(a).?.row]);

    // a is buried: its handle dies with it, the index comes back with a new generation
    store.release(handle.indexOf(a));
    try std.testing.expectEqual(@as(?Slot, null), store.find(a));
    const d = (try store.create(gpa, .npc, .{ .health = 4 })).?;
    try std.testing.expectEqual(handle.indexOf(a), handle.indexOf(d));
    try std.testing.expect(d != a);
    try std.testing.expectEqual(@as(f32, 2), store.alive.items(.health)[store.find(b).?.row]);
}

test "a saved store loads back the same" {
    const gpa = std.testing.allocator;
    const Row = struct { index: u16 = 0, health: f32 = 0, team: u8 = 0 };
    var store = Store(Row).init();
    defer store.deinit(gpa);
    const a = (try store.create(gpa, .hero, .{ .health = 10, .team = 1 })).?;
    const b = (try store.create(gpa, .hero, .{ .health = 20, .team = 2 })).?;
    try store.move(gpa, handle.indexOf(a), .fallen);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try store.save(gpa, &bytes);

    var loaded = Store(Row).init();
    defer loaded.deinit(gpa);
    try std.testing.expect(try loaded.load(gpa, bytes.items));
    try std.testing.expectEqual(List.fallen, loaded.find(a).?.list);
    try std.testing.expectEqual(@as(f32, 20), loaded.alive.items(.health)[loaded.find(b).?.row]);
    try std.testing.expectEqual(@as(u16, handle.per_kind - 2), loaded.free_count);
    // A store whose rows changed keeps the columns it shares, by name, and defaults the rest
    var other = Store(struct { index: u16 = 0, mana: f64 = 7, health: f32 = 0, team: u16 = 9 }).init();
    defer other.deinit(gpa);
    try std.testing.expect(try other.load(gpa, bytes.items));
    const row = other.find(b).?.row;
    try std.testing.expectEqual(@as(f32, 20), other.alive.items(.health)[row]); // same name, same size
    try std.testing.expectEqual(@as(f64, 7), other.alive.items(.mana)[row]); // new: its default
    try std.testing.expectEqual(@as(u16, 9), other.alive.items(.team)[row]); // changed size: its default
    try std.testing.expect(!try other.load(gpa, "not a save"));
}
