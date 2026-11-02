extends SceneTree
## Stats and items on the main map (waves off). OUT=<prefix> for screenshots.

var _out := OS.get_environment("OUT")
var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var scene: Node3D = support.call(&"open_map", self, ["knight", "ranger", "mage"])  # the party these checks expect
	var camera: RTSCamera = scene.get_node("RTSCamera")
	camera.edge_scroll = false
	var registry: UnitRegistry = scene.get_node("UnitRegistry")
	var commander: Commander = scene.get_node("Commander")
	var party: PartyInventory = scene.get_node("Party")
	var window: InventoryWindow = scene.get_node("HUD/Inventory")
	await process_frame
	scene.get_node("CreepWaves").set("_next_wave_time", 999.0)
	await create_timer(1.0).timeout
	var knight := registry.unit_of(commander.heroes[0])
	var ranger := registry.unit_of(commander.heroes[1])
	var mage := registry.unit_of(commander.heroes[2])

	# Level 1 keeps the old numbers
	_near("knight health", registry.max_health_of(knight.handle), 600.0)
	_near("knight mana", knight.max_mana, 255.0)
	_near("knight mana regen", knight.stats.value(Stats.Stat.MANA_REGEN), 0.9)
	_near("knight armor", knight.stats.value(Stats.Stat.ARMOR), 4.0)
	_near("knight damage", knight.attack_damage(), 42.0)
	_near("knight attack cooldown", knight.definition.attack_cooldown / knight.attack_speed_factor(), 1.1, 0.01)
	_near("ranger health", registry.max_health_of(ranger.handle), 280.0)
	_near("ranger mana", ranger.max_mana, 225.0)
	_near("ranger damage", ranger.attack_damage(), 26.0)
	_near("ranger evasion % (0.1 per Dexterity)", ranger.stats.effective(Stats.Stat.EVASION), 100.0 * 1.9 / 101.9, 0.001)
	_near("mage health", registry.max_health_of(mage.handle), 240.0)
	_near("mage mana", mage.max_mana, 285.0)
	_near("mage mana regen", mage.stats.value(Stats.Stat.MANA_REGEN), 1.4)
	_near("mage crit % (0.1 per Dexterity)", mage.stats.effective(Stats.Stat.CRIT_CHANCE), 100.0 * 1.7 / 101.7, 0.001)
	_near("knight spell damage (0.1% per Willpower)", knight.stats.value(Stats.Stat.SPELL_DAMAGE), 1.8, 0.001)
	_near("ranger spell damage (0.1% per Strength)", ranger.stats.value(Stats.Stat.SPELL_DAMAGE), 1.0, 0.001)
	_near("mage cast speed (0.1% per Dexterity)", mage.stats.value(Stats.Stat.CAST_SPEED), 1.7, 0.001)
	var blizzard_cost := mage.ability_at(0).mana_cost_at(1)
	_near("mage mana cost reduced by Focus", mage.mana_cost(0), blizzard_cost * (1.0 - 1.6 / 101.6), 0.01)
	_check("passives listed: knight 5, mage 6, ranger 3", knight.definition.all_passives().size() == 5
			and mage.definition.all_passives().size() == 6 and ranger.definition.all_passives().size() == 3)
	var minion: UnitDefinition = load("res://data/units/skeleton_minion.tres")
	_check("undead get the Undead faction passive", minion.all_passives().has(UnitDefinition.UNDEAD_PASSIVE))
	print("   bag %d items, weight %.1f / %.1f" % [party.bag.size(), party.carried_weight(), party.capacity])

	# Equip from the bag
	var weight_before := party.carried_weight()
	_check("equip mace", party.move(_bag(party, "War Mace"), _equip(knight, Equipment.WEAPON)).is_empty())
	_check("equip chainmail", party.move(_bag(party, "Chainmail"), _equip(knight, 3)).is_empty())
	_check("chainmail refused in the head slot", not party.move(_bag(party, "Leather Cap"), _equip(knight, 3)).is_empty())
	_near("knight damage with mace", knight.attack_damage(), 50.0)
	_near("knight armor with chainmail", knight.stats.value(Stats.Stat.ARMOR), 7.0)
	_check("attack type from the weapon", knight.attack_type() != null and knight.attack_type().display_name == "Crushing")
	_near("worn items leave the bag weight", party.carried_weight(), weight_before - 22.0)
	var strength_before := knight.stats.value(Stats.Stat.STRENGTH)
	party.quick_move(_bag(party, "Gauntlets of Ogre Strength"), knight)
	_near("gauntlets: +3 strength", knight.stats.value(Stats.Stat.STRENGTH), strength_before + 3.0)
	_near("gauntlets: +75 health", registry.max_health_of(knight.handle), 675.0)

	# Attack type and flat armor: mace (Crushing, +30% vs Heavy) on a skeleton warrior (Heavy, 3 armor)
	var warrior := registry.spawn_npc(load("res://data/units/skeleton_warrior.tres"), 2, Vector3(-30, 0, 30), scene.get_node("NorthSpawner"))
	registry.hold_position(warrior)
	var knight_was := knight.global_position
	knight.teleport(Vector3(-28.5, 0, 30))  # within reach: a melee blow from farther misses (attack range + MELEE_REACH_BUFFER)
	var before := registry.health_of(warrior)
	registry.deliver_attack(knight.handle, warrior, 50.0, knight.definition)
	_near("crushing hit on heavy: 50 x 1.3 - 3", before - registry.health_of(warrior), 62.0)
	knight.teleport(knight_was)
	before = registry.health_of(warrior)
	registry.apply_damage(warrior, 2.0, knight.handle)
	_near("armor never takes a hit below 0.5", before - registry.health_of(warrior), 0.5)
	registry.kill(warrior)

	# Spell damage: the knight's spells grow with Willpower
	var undead := registry.spawn_npc(load("res://data/units/skeleton_minion.tres"), 2, Vector3(-32, 0, 30), scene.get_node("NorthSpawner"))
	registry.hold_position(undead)
	before = registry.health_of(undead)
	registry.apply_damage(undead, 100.0, knight.handle, false)
	_near("spell hit grows by spell damage (1.8%)", before - registry.health_of(undead), 101.8, 0.01)
	registry.kill(undead)
	# Twin weapons combine into one weapon
	party.move(_bag(party, "Lightbrand"), _cell(2))
	party.move(_bag(party, "Firebrand"), _cell(3))
	_check("Lightbrand + Firebrand = Twin Brands", _names(party.combine).has("Twin Brands"))
	party.disassemble(_names(party.combine).find("Twin Brands"))
	_check("Twin Brands come apart into both blades", _names(party.combine).has("Lightbrand") and _names(party.combine).has("Firebrand"))
	for cell in PartyInventory.COMBINE_CELLS:
		if party.combine[cell] != null:
			party.move(_cell(cell), PartyInventory.Place.new(PartyInventory.Area.BAG, 0))

	# Combine grid: two parts make Swift Marchers, which comes apart again
	party.move(_bag(party, "Boots of Speed"), _cell(0))
	_check("one part alone doesn't combine", party.combine[0] != null and party.combine[0].display_name == "Boots of Speed")
	party.move(_bag(party, "Gloves of Haste"), _cell(4))
	_check("Swift Marchers combined", party.combine[4] != null and party.combine[4].display_name == "Swift Marchers" and party.combine[0] == null)
	_check("take apart", party.disassemble(4).is_empty())
	_check("parts back in the grid", _names(party.combine).has("Boots of Speed") and _names(party.combine).has("Gloves of Haste"))
	_check("taking apart doesn't recombine", not _names(party.combine).has("Swift Marchers"))
	# Four-part recipe
	for cell in PartyInventory.COMBINE_CELLS:
		if party.combine[cell] != null:
			party.move(_cell(cell), PartyInventory.Place.new(PartyInventory.Area.BAG, 0))
	for name in ["Circlet of Nobility", "Gauntlets of Ogre Strength", "Slippers of Agility", "Mantle of Intelligence"]:
		if name == "Gauntlets of Ogre Strength":
			party.move(_equip(knight, 5), _cell(1))  # straight from the knight's hands
		else:
			party.move(_bag(party, name), _cell(party.combine.find(null)))
	_check("Crown of Kings combined", _names(party.combine).has("Crown of Kings"))
	_near("knight lost the gauntlets' health", registry.max_health_of(knight.handle), 600.0)
	# Amulet of Mending: an item ability on the bar
	party.move(_bag(party, "Periapt of Vitality"), _cell(party.combine.find(null)))
	party.move(_bag(party, "Pendant of Willpower"), _cell(party.combine.find(null)))
	var amulet_cell := _names(party.combine).find("Amulet of Mending")
	_check("Amulet of Mending combined", amulet_cell >= 0)
	party.move(_cell(amulet_cell), _equip(knight, 8))
	_check("item ability on the bar", knight.ability_at(Unit.HERO_ABILITY_SLOTS) != null and knight.ability_at(Unit.HERO_ABILITY_SLOTS).display_name == "Mending Light")
	registry.apply_damage(ranger.handle, 200.0, UnitRegistry.NONE, false)
	var hurt := registry.health_of(ranger.handle)
	knight.order_cast(Unit.HERO_ABILITY_SLOTS, ranger.handle, ranger.global_position, Unit.Queue.NONE)
	await create_timer(1.5).timeout
	_near("Mending Light healed 150 (plus regen)", registry.health_of(ranger.handle) - hurt, 150.0, 2.0)
	_check("item ability on cooldown", knight.ability_cooldown(Unit.HERO_ABILITY_SLOTS) > 15.0)

	# Level up grows the class's stats
	var health_before := registry.max_health_of(knight.handle)
	knight.add_experience(200.0)
	_near("level 2: +2.7 strength = +67.5 health", registry.max_health_of(knight.handle) - health_before, 67.5)

	# Pick up the sword lying on the map
	var bag_before := party.bag.size()
	var sword := scene.find_children("DroppedSword*", "", true, false)
	if not sword.is_empty():
		knight.teleport((sword[0] as Node3D).global_position + Vector3(0.5, 0, 0))
		knight.order_pickup(sword[0] as ItemPickup, Unit.Queue.NONE)  # smart-click; walking over isn't enough
		await create_timer(0.6).timeout
		_check("smart-clicked the sword: picked up", party.bag.size() == bag_before + 1)

	# Screenshots: inventory window and the item bar tooltip
	commander.select_hero(0)
	camera.center_on(knight.global_position)
	window.toggle()
	await create_timer(0.3).timeout
	var cell := _find_cell(window, "Amulet of Mending")
	if cell != null:
		_hover(cell.get_global_rect().get_center())
	await create_timer(0.3).timeout
	await _shot("inventory")
	window.toggle()
	await create_timer(0.2).timeout
	var panel: SpellPanel = scene.get_node("HUD/SpellPanel")
	_hover(panel._info_icon.get_global_rect().get_center())
	await create_timer(0.3).timeout
	await _shot("item_bar_passive")
	_hover(panel._attack_icon.get_global_rect().get_center())
	await create_timer(0.3).timeout
	await _shot("item_bar_attack")
	print("FAILURES: %d" % _failures)
	quit()


func _bag(party: PartyInventory, item_name: String) -> PartyInventory.Place:
	for i in party.bag.size():
		if party.bag[i].display_name == item_name:
			return PartyInventory.Place.new(PartyInventory.Area.BAG, i)
	push_error("not in bag: " + item_name)
	return PartyInventory.Place.new(PartyInventory.Area.BAG, -1)


func _equip(hero: Unit, index: int) -> PartyInventory.Place:
	return PartyInventory.Place.new(PartyInventory.Area.EQUIPMENT, index, hero)


func _cell(index: int) -> PartyInventory.Place:
	return PartyInventory.Place.new(PartyInventory.Area.COMBINE, index)


func _names(items: Array[ItemDefinition]) -> Array[String]:
	var names: Array[String] = []
	for item in items:
		names.append(item.display_name if item != null else "")
	return names


func _find_cell(node: Node, item_name: String) -> ItemCell:
	for child in node.find_children("*", "ItemCell", true, false):
		var cell := child as ItemCell
		if cell.item != null and cell.item.display_name == item_name:
			return cell
	return null


func _hover(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	Input.parse_input_event(motion)


func _near(what: String, value: float, expected: float, tolerance := 0.05) -> void:
	var ok := absf(value - expected) <= tolerance
	print("%s %s: %.3f (expected %.3f)" % ["ok  " if ok else "FAIL", what, value, expected])
	if not ok:
		_failures += 1


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("%s_%s.png" % [_out, shot_name])
