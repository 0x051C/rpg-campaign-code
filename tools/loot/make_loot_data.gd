extends SceneTree

## Writes the loot data (DIRECTION.md 1): the affix table (data/loot/affixes.tres), plain bases for the
## slots that only had recipe parts (a ring, an amulet, boots, gloves), and the catalog's loot_bases:
## every wearable item that is neither a recipe's part nor its result.
##
##   godot --headless --path . --script res://tools/loot/make_loot_data.gd [-- --rewrite]
##
## Keeps an existing affix table unless --rewrite (it's yours to tune).

const S := ItemDefinition.Slot
const ARMOR_SLOTS := [S.HEAD, S.SHOULDERS, S.CHEST, S.ARMS, S.HANDS, S.LEGS, S.BOOTS]
const JEWELRY := [S.NECK, S.RING]

## word, suffix, stat, at level 1, per level, slots (empty: any), weight, from level
const AFFIXES := [
	["Sturdy", false, Stats.Stat.ARMOR, 1.0, 0.35, ARMOR_SLOTS, 12, 1],
	["Jagged", false, Stats.Stat.ATTACK_DAMAGE, 3.0, 1.2, [S.WEAPON, S.HANDS, S.RING], 12, 1],
	["Hale", false, Stats.Stat.MAX_HEALTH, 20.0, 8.0, ARMOR_SLOTS + JEWELRY, 12, 1],
	["Sage's", false, Stats.Stat.MAX_MANA, 20.0, 7.0, [S.HEAD, S.NECK, S.RING, S.WEAPON], 10, 1],
	["Keen", false, Stats.Stat.CRIT_CHANCE, 4.0, 1.0, [S.WEAPON, S.HANDS, S.RING, S.NECK], 8, 2],
	["Brutal", false, Stats.Stat.CRIT_DAMAGE, 10.0, 2.0, [S.WEAPON], 6, 3],
	["Arcane", false, Stats.Stat.SPELL_DAMAGE, 4.0, 1.0, [S.WEAPON, S.HEAD, S.NECK, S.RING], 8, 1],
	["Nimble", false, Stats.Stat.EVASION, 4.0, 1.0, [S.BOOTS, S.LEGS, S.CHEST, S.ARMS], 8, 2],
	["of the Bear", true, Stats.Stat.STRENGTH, 1.0, 0.4, [], 10, 1],
	["of the Fox", true, Stats.Stat.DEXTERITY, 1.0, 0.4, [], 10, 1],
	["of the Owl", true, Stats.Stat.INTELLIGENCE, 1.0, 0.4, [], 10, 1],
	["of the Oak", true, Stats.Stat.WILLPOWER, 1.0, 0.4, [], 10, 1],
	["of Mending", true, Stats.Stat.HEALTH_REGEN, 0.4, 0.15, [S.CHEST, S.NECK, S.RING, S.HEAD], 8, 1],
	["of the Spring", true, Stats.Stat.MANA_REGEN, 0.25, 0.1, [S.HEAD, S.NECK, S.RING, S.WEAPON], 8, 1],
	["of Haste", true, Stats.Stat.MOVE_SPEED, 0.15, 0.03, [S.BOOTS], 10, 1],
	["of Swiftness", true, Stats.Stat.ATTACK_SPEED, 5.0, 1.5, [S.WEAPON, S.HANDS, S.ARMS], 8, 1],
	["of Quickening", true, Stats.Stat.CAST_SPEED, 5.0, 1.5, [S.HEAD, S.NECK, S.WEAPON, S.HANDS], 8, 2],
]
## file, name, glyph, color, slot, weight, bonuses
const BASES := [
	["iron_ring", "Iron Ring", "Ri", Color(0.6, 0.6, 0.62), S.RING, 0.1, {}],
	["bone_amulet", "Bone Amulet", "Am", Color(0.85, 0.8, 0.68), S.NECK, 0.2, {}],
	["worn_boots", "Worn Boots", "Bt", Color(0.45, 0.33, 0.22), S.BOOTS, 4.0, {Stats.Stat.ARMOR: 1.0}],
	["work_gloves", "Work Gloves", "Gl", Color(0.55, 0.45, 0.3), S.HANDS, 2.0, {Stats.Stat.ARMOR: 1.0}],
]


func _initialize() -> void:
	var rewrite := OS.get_cmdline_user_args().has("--rewrite")
	DirAccess.make_dir_recursive_absolute("res://data/loot")
	if rewrite or not FileAccess.file_exists(LootRoller.AFFIXES):
		var table := AffixTable.new()
		for entry: Array in AFFIXES:
			var affix := ItemAffix.new()
			affix.word = entry[0]
			affix.suffix = entry[1]
			affix.stat = entry[2]
			affix.value = entry[3]
			affix.per_level = entry[4]
			affix.slots.assign(entry[5])
			affix.weight = entry[6]
			affix.min_level = entry[7]
			table.affixes.append(affix)
		print("affixes: ", error_string(ResourceSaver.save(table, LootRoller.AFFIXES)))
	var catalog: ItemCatalog = load(LootRoller.CATALOG)
	for entry: Array in BASES:
		var path := "res://data/items/%s.tres" % entry[0]
		if not FileAccess.file_exists(path):
			var item := ItemDefinition.new()
			item.display_name = entry[1]
			item.icon_glyph = entry[2]
			item.icon_color = entry[3]
			item.slot = entry[4]
			item.weight = entry[5]
			item.bonuses.assign(entry[6])
			print(entry[0], ": ", error_string(ResourceSaver.save(item, path)))
		var base: ItemDefinition = load(path)
		if not catalog.items.has(base):
			catalog.items.append(base)
	catalog.loot_bases.clear()
	for item in catalog.items:
		if item.is_wearable() and catalog.recipe_for(item) == null and catalog.uses_of(item).is_empty():
			catalog.loot_bases.append(item)
	var names := catalog.loot_bases.map(func(item: ItemDefinition) -> String: return item.display_name)
	print("loot bases (%d): %s" % [names.size(), ", ".join(names)])
	print("catalog: ", error_string(ResourceSaver.save(catalog, LootRoller.CATALOG)))
	quit()
