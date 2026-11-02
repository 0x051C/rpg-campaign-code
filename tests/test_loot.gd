extends SceneTree
## Random loot (DIRECTION.md 1): magic and rare items rolled from plain bases with affixes that fit
## their slot and grow with item level; what monsters drop (champions more); named parts from the
## kinds that carry them; drops landing where a monster falls; rolled items kept by a save.

const CAP := preload("res://data/items/leather_cap.tres")
const BOOTS := preload("res://data/items/worn_boots.tres")
const LIGHTBRAND := preload("res://data/items/lightbrand.tres")
const SKELETON := preload("res://data/units/skeleton_warrior.tres")

var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")

	# Rolling
	var magic := LootRoller.roll(CAP, 5, ItemDefinition.Rarity.MAGIC)
	_check("magic: one or two affixes, named after them", magic.rolled.size() in [1, 2] and magic.display_name.contains("Leather Cap")
			and magic.display_name != "Leather Cap" and magic.base_item == CAP and magic.item_level == 5)
	var sums := true
	for stat: Stats.Stat in magic.bonuses:
		sums = sums and is_equal_approx(magic.bonuses[stat], CAP.bonuses.get(stat, 0.0) + magic.rolled.get(stat, 0.0))
	_check("its bonuses are the base's plus the rolls", sums)
	_check("the base itself isn't touched", CAP.rolled.is_empty() and CAP.bonuses.size() == 1)
	var rare := LootRoller.roll(CAP, 5, ItemDefinition.Rarity.RARE)
	_check("rare: three or four affixes, a made-up name", rare.rolled.size() >= 3 and not rare.display_name.contains("Leather"))
	_check("worth more than its base", rare.value() > CAP.value())
	var haste_on_caps := 0
	var haste_on_boots := 0
	for i in 60:
		haste_on_caps += 1 if LootRoller.roll(CAP, 10, ItemDefinition.Rarity.RARE).rolled.has(Stats.Stat.MOVE_SPEED) else 0
		haste_on_boots += 1 if LootRoller.roll(BOOTS, 10, ItemDefinition.Rarity.RARE).rolled.has(Stats.Stat.MOVE_SPEED) else 0
	_check("affixes keep to their slots: haste on boots, never on a cap", haste_on_caps == 0 and haste_on_boots > 0)
	var low := 0.0
	var high := 0.0
	for i in 40:
		low += _total(LootRoller.roll(CAP, 1, ItemDefinition.Rarity.RARE))
		high += _total(LootRoller.roll(CAP, 12, ItemDefinition.Rarity.RARE))
	_check("deeper drops roll bigger", high > low * 1.5)

	# What monsters drop
	var common_items := 0
	var common_gold := 0
	for i in 400:
		var loot := LootRoller.drops_for(SKELETON)
		common_items += loot.items.size()
		common_gold += 1 if loot.gold > 0 else 0
	_check("a common monster: now and then gold, rarely an item", common_gold > 80 and common_gold < 220 and common_items > 5 and common_items < 80)
	var champion := SKELETON.leveled(4, [load("res://data/modifiers/extra_strong.tres")])
	var champion_items := 0
	var always_gold := true
	for i in 100:
		var loot := LootRoller.drops_for(champion)
		champion_items += loot.items.size()
		always_gold = always_gold and loot.gold > 0
	_check("a champion: gold every time, mostly an item", always_gold and champion_items > 55)
	_check("loot rate 0: nothing", LootRoller.drops_for(champion, 0.0).items.is_empty() and LootRoller.drops_for(champion, 0.0).gold == 0)
	var carrier := SKELETON.duplicate() as UnitDefinition
	carrier.named_drops = [LIGHTBRAND]
	carrier.named_drop_chance = 1.0
	_check("a kind that carries a named part drops it", LootRoller.drops_for(carrier).items.has(LIGHTBRAND))

	# Drops land where a monster falls
	var map: Node3D = support.call(&"open_map", self, ["maren"], "res://scenes/maps/story_template.tscn")
	await create_timer(0.5).timeout
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var spawner := CreepSpawner.new()
	spawner.team = UnitRegistry.CREATURE_TEAM
	spawner.active = false
	spawner.modifiers = [load("res://data/modifiers/stone_skin.tres")]
	map.add_child(spawner)
	registry.monster_level = 3
	var before := get_nodes_in_group(ItemPickup.RUNTIME_GROUP).size()
	var victim := registry.spawn_npc(SKELETON, spawner.team, Vector3(20, 0, 20), spawner)
	registry.apply_damage(victim, 1.0e6, UnitRegistry.NONE, false)
	await process_frame
	_check("a champion falls: its gold (and loot) on the ground", get_nodes_in_group(ItemPickup.RUNTIME_GROUP).size() > before)

	# A rolled item: worn, it counts; saved, it comes back as itself
	var maren := registry.unit_of((map.get_node("Commander") as Commander).heroes[0])
	var sturdy := LootRoller.roll(CAP, 8, ItemDefinition.Rarity.MAGIC)
	var head := Equipment.place_for(maren.equipment, sturdy)
	maren.equipment[head] = null
	maren.recalculate_stats()
	var bare := maren.stats.value(Stats.Stat.ARMOR)
	maren.equipment[head] = sturdy
	maren.recalculate_stats()
	_check("worn, a rolled item's bonuses count", is_equal_approx(maren.stats.value(Stats.Stat.ARMOR) - bare, sturdy.bonuses.get(Stats.Stat.ARMOR, 0.0)))
	var saved := SaveCodec.decode_resource(SaveCodec.encode_resource(rare)) as ItemDefinition
	_check("saved and loaded: name, rarity, rolls, base", saved.display_name == rare.display_name and saved.rarity == rare.rarity
			and saved.rolled == rare.rolled and saved.base_item == CAP and saved.item_level == 5)
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _total(item: ItemDefinition) -> float:
	var total := 0.0
	for stat: Stats.Stat in item.rolled:
		total += absf(item.rolled[stat])
	return total


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
