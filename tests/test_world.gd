extends SceneTree
## Exits need the whole party for 5 s, checkpoints save, reviving, chests, drops, loot left
## behind, talk debounce, aiming through the selection panel.

var _failures := 0
var campaign: Node


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	campaign = Campaign.current
	for header in campaign.list_saves():
		campaign.delete_save(header.slot)
	campaign.flags = {}
	change_scene_to_file("res://scenes/maps/village.tscn")
	await create_timer(1.5).timeout
	var map := current_scene
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var commander: Commander = map.get_node("Commander")
	var party: PartyInventory = map.get_node("Party")
	var heroes: Array[Unit] = []
	for handle in commander.heroes:
		heroes.append(registry.unit_of(handle))

	# Talking: three heroes arriving together is one talk, not three
	var innkeeper: NeutralSpawn = map.get_node("Villagers/Innkeeper")
	var inn := map.get_node_or_null("Story/SleepingBoar") as Inn
	if inn != null:
		inn.host = null  # talking to Brann here is about talking, not his beds (test_story has those)
	var talks := [0]
	registry.talked_to.connect(func(_n: int, _s: int) -> void: talks[0] += 1)
	for hero in heroes:
		registry.talk(innkeeper.handle, hero.handle)
	_check("three heroes talking at once count as one talk", talks[0] == 1)
	_check("talk range is ~300 noh units", is_equal_approx(Unit.TALK_DISTANCE, 300.0 / 48.0))

	# Aiming a spell through the selection panel: one click casts on that unit
	var knight := heroes[0]
	knight.skill_points = 3
	knight.learn(0)  # Holy Light
	registry.apply_damage(heroes[1].handle, 150.0, UnitRegistry.NONE, false)
	commander.select(knight.handle)
	commander.control_selection.assign([knight.handle, heroes[1].handle])
	commander.active = knight.handle
	commander.activate_ability(0)
	var panel: SelectionPanel = map.get_node("HUD/Bottom/SelectionPanel")
	await process_frame
	panel._on_slot_pressed(1)  # the second button: heroes[1]
	_check("one click on the unit's button cast the spell", knight.orders.size() == 1 and knight.orders[0].type == UnitOrder.Type.CAST
			and knight.orders[0].target == heroes[1].handle)
	_check("the aimed spell ended, the caster stayed active", commander.active_slot < 0 and commander.active == knight.handle)
	knight.order_stop()

	# Chest in the inn: walking up opens it, items spill out
	var chest: Chest = map.get_node("NavigationRegion3D/Inn/InnChest")
	knight.teleport(chest.global_position + Vector3(0, 0, -1.4))  # behind it, away from where the loot lands
	await create_timer(0.6).timeout
	_check("chest opened", chest.opened)
	_check("its two items and its gold lie in front of it", _loot_items() == 2 and _loot_gold() == 40)

	# Reviving: kill the ranger, stand the knight on the body
	var ranger := heroes[1]
	registry.kill(ranger.handle)
	await create_timer(0.3).timeout
	_check("ranger fell", not ranger.is_alive())
	knight.teleport(ranger.global_position + Vector3(0.5, 0, 0))
	await create_timer(3.2).timeout
	_check("one helper: not yet after 3 s", not ranger.is_alive() and ranger.revive_progress() > 0.4)
	heroes[2].teleport(ranger.global_position + Vector3(-0.5, 0, 0))
	await create_timer(1.6).timeout
	_check("two helpers finish it", ranger.is_alive() and registry.is_alive(ranger.handle))
	_near("revived with half health", registry.health_of(ranger.handle) / registry.max_health_of(ranger.handle), 0.5, 0.05)

	# Checkpoint by the well: the whole party saves
	var well: Checkpoint = map.get_node("WellCheckpoint")
	heroes[0].teleport(well.global_position)
	await create_timer(2.0).timeout
	_check("one hero alone doesn't save", not campaign.list_saves().any(func(h: Dictionary) -> bool: return h.label == "Checkpoint"))
	for i in heroes.size():
		heroes[i].teleport(well.global_position + Vector3(i * 0.9 - 0.9, 0, 0))
	await create_timer(2.2).timeout
	_check("the whole party at the well saved", campaign.list_saves().any(func(h: Dictionary) -> bool: return h.label == "Checkpoint"))

	# Exit: one hero isn't enough; the party needs 5 s together
	var exit: MapExit = map.get_node("ToLane")
	heroes[0].teleport(exit.global_position)
	await create_timer(5.5).timeout
	_check("one hero on the exit doesn't leave", current_scene == map)
	for i in heroes.size():
		heroes[i].teleport(exit.global_position + Vector3(i * 0.9 - 0.9, 0, 0))
	await create_timer(3.0).timeout
	_check("not before 5 s", current_scene == map)
	await create_timer(3.0).timeout
	await support.call(&"scene_changed", self, map)
	_check("the whole party left after 5 s", current_scene != map and current_scene.scene_file_path.ends_with("main.tscn"))

	# Drops: a creep given an item drops it; walk away, come back: the loot waits at the entrance
	map = current_scene
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	map.get_node("CreepWaves").set("_next_wave_time", 999.0)
	var north: CreepSpawner = map.get_node("NorthSpawner")
	var ambusher := registry.spawn_npc(load("res://data/units/skeleton_warrior.tres"), 2, Vector3(20, 0, 20), north)
	registry.set_drops(ambusher, [load("res://data/items/crown_of_kings.tres")])
	registry.kill(ambusher)
	await process_frame
	var dropped := get_nodes_in_group(ItemPickup.RUNTIME_GROUP)
	_check("the ambusher dropped its Crown of Kings", dropped.size() == 1 and (dropped[0] as ItemPickup).item.display_name == "Crown of Kings")
	# Save and load keep loot on the ground
	_check("save", campaign.save_game("loot").is_empty())
	campaign.load_game("loot")
	await campaign.loaded
	await process_frame
	_check("loot survives a load", get_nodes_in_group(ItemPickup.RUNTIME_GROUP).size() == 1)
	# Leave to the village (whole party on the exit), come back
	map = current_scene
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	var to_village: MapExit = map.get_node("ToVillage")
	for i in commander.heroes.size():
		registry.unit_of(commander.heroes[i]).teleport(to_village.global_position + Vector3(i * 0.9 - 0.9, 0, 0))
	await create_timer(6.0).timeout
	await support.call(&"scene_changed", self, map)
	_check("in the village again", current_scene.scene_file_path.ends_with("village.tscn"))
	await create_timer(0.5).timeout
	_check("the opened chest stays open", (current_scene.get_node("NavigationRegion3D/Inn/InnChest") as Chest).opened)
	_check("its items don't come back into it", _loot_items() == 2)  # the two left on the floor wait at the entrance
	map = current_scene
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	var to_lane: MapExit = map.get_node("ToLane")
	for i in commander.heroes.size():
		registry.unit_of(commander.heroes[i]).teleport(to_lane.global_position + Vector3(i * 0.9 - 0.9, 0, 0))
	await create_timer(6.0).timeout
	await support.call(&"scene_changed", self, map)
	await create_timer(0.3).timeout
	var waiting := get_nodes_in_group(ItemPickup.RUNTIME_GROUP).filter(func(n: Node) -> bool: return (n as ItemPickup).item != null)
	var entrance: Node3D = current_scene.get_node("FromVillage")
	_check("the crown waits at the lane's entrance", waiting.size() == 1
			and (waiting[0] as Node3D).global_position.distance_to(entrance.global_position) < 6.0)
	print("FAILURES: %d" % _failures)
	quit()


func _loot_items() -> int:
	return get_nodes_in_group(ItemPickup.RUNTIME_GROUP).filter(func(n: Node) -> bool: return (n as ItemPickup).item != null).size()


func _loot_gold() -> int:
	var total := 0
	for node in get_nodes_in_group(ItemPickup.RUNTIME_GROUP):
		total += (node as ItemPickup).gold
	return total


func _near(what: String, value: float, expected: float, tolerance := 0.05) -> void:
	var ok := absf(value - expected) <= tolerance
	print("%s %s: %.3f (expected %.3f)" % ["ok  " if ok else "FAIL", what, value, expected])
	if not ok:
		_failures += 1


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
