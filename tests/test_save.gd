extends SceneTree
## Save, load and travel. Uses the Campaign autoload like the game does.

var _failures := 0
var campaign: Node


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	campaign = Campaign.current
	for header in campaign.list_saves():
		campaign.delete_save(header.slot)
	support.call(&"open_map", self, ["knight", "ranger", "mage"])  # the party these checks expect
	await create_timer(1.5).timeout
	var map := current_scene
	map.get_node("CreepWaves").set("_next_wave_time", 999.0)
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var commander: Commander = map.get_node("Commander")
	var party: PartyInventory = map.get_node("Party")
	var knight := registry.unit_of(commander.heroes[0])
	var ranger := registry.unit_of(commander.heroes[1])

	# Make the map's state interesting
	knight.add_experience(600.0)
	knight.learn(0)
	party.move(_bag(party, "War Mace"), _equip(knight, Equipment.WEAPON))
	party.move(_bag(party, "Ring of Protection"), _equip(knight, 9))
	party.move(_bag(party, "Boots of Speed"), PartyInventory.Place.new(PartyInventory.Area.COMBINE, 2))
	var north: CreepSpawner = map.get_node("NorthSpawner")
	var enemy := registry.spawn_npc(load("res://data/units/skeleton_warrior.tres"), 2, Vector3(5, 0, -20), north)
	registry.apply_damage(enemy, 100.0, UnitRegistry.NONE, false)
	var doomed := registry.spawn_npc(load("res://data/units/skeleton_minion.tres"), 2, Vector3(-5, 0, -20), north)
	registry.kill(doomed)
	registry.apply_damage(ranger.handle, 120.0, UnitRegistry.NONE, false)
	var sword_pickup: ItemPickup = map.find_children("DroppedSword*", "", true, false)[0]
	knight.teleport(sword_pickup.ground_spot() + Vector3(0.5, 0, 0))
	knight.order_pickup(sword_pickup, Unit.Queue.NONE)  # pick up the sword
	await create_timer(3.0).timeout  # the corpse appears, waves clock runs
	commander.select(ranger.handle)
	commander.save_selection_set(2)
	var expected := _snapshot(map)
	print("   before save: ", expected)
	_check("save", campaign.save_game("test", "Test save").is_empty())
	_check("save listed", campaign.list_saves().any(func(h: Dictionary) -> bool: return h.slot == "test" and h.heroes[0].level == 3))

	# Change things, then load
	knight.teleport(Vector3(30, 0, 30))
	registry.apply_damage(knight.handle, 300.0, UnitRegistry.NONE, false)
	party.add(load("res://data/items/chainmail.tres"))
	_check("load", campaign.load_game("test").is_empty())
	await campaign.loaded  # compare right after the restore, before anything moves
	map = current_scene
	var restored := _snapshot(map)
	print("   after load:  ", restored)
	for key: String in expected:
		var same: bool = var_to_str(expected[key]) == var_to_str(restored[key])
		if not same and expected[key] is float:
			same = absf(expected[key] - restored[key]) < 0.01
		_check("restored " + key, same)
		if not same:
			print("      expected ", expected[key], " got ", restored[key])
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	var resumed_at := registry.position_of(enemy)
	var spawn_point := (map.get_node("NorthSpawner") as Node3D).global_position
	await process_frame  # taken pickups are freed at the end of the frame
	_check("one sword pickup gone", map.find_children("DroppedSword*", "", true, false).is_empty())
	_check("neutral-free map has no stray rows", registry.count_alive(UnitRegistry.Kind.NPC, UnitRegistry.NEUTRAL_TEAM) == 0)
	await create_timer(3.0).timeout  # the restored map runs: creeps think, heroes regenerate
	_check("restored enemy still alive and on its row", registry.is_alive(enemy))
	# Walking on from where it was saved: no farther than it walks in 3 s, and not back to its spawner
	var now_at := registry.position_of(enemy)
	var walk := (load("res://data/units/skeleton_warrior.tres") as UnitDefinition).move_speed * 3.0 + 1.0
	var moved := now_at.distance_to(resumed_at)
	_check("restored creeps walk on from their place (moved %.1f m, at most %.1f)" % [moved, walk],
			moved <= walk and now_at.distance_to(spawn_point) >= resumed_at.distance_to(spawn_point) - 0.5)

	# Travel to the village with the party
	campaign.travel("res://scenes/maps/village.tscn", "FromLane")
	await create_timer(1.5).timeout
	await support.call(&"scene_changed", self, map)
	map = current_scene
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	party = map.get_node("Party")
	var village_knight := registry.unit_of(commander.heroes[0])
	_check("arrived in the village", map.scene_file_path.ends_with("village.tscn"))
	_check("knight kept level 3 and the mace", village_knight.level == 3 and village_knight.equipment[Equipment.WEAPON] != null
			and village_knight.equipment[Equipment.WEAPON].display_name == "War Mace")
	_check("bag came along (sword included)", _has(party, "Militia Sword") and party.combine[2] != null)
	var arrival: Node3D = map.get_node("FromLane")
	_check("arrived at the FromLane marker", village_knight.global_position.distance_to(arrival.global_position) < 4.0)
	var villagers := registry.count_alive(UnitRegistry.Kind.NPC, UnitRegistry.NEUTRAL_TEAM)
	print("   %d villagers in Coldharbour" % villagers)
	_check("villagers spawned", villagers >= 2)
	_check("autosave written", campaign.list_saves().any(func(h: Dictionary) -> bool: return h.slot == "autosave"))

	# Save in the village, load it: neutrals keep their handles, no duplicates
	_check("save in village", campaign.save_game("village").is_empty())
	campaign.load_game("village")
	await create_timer(1.0).timeout
	map = current_scene
	registry = map.get_node("UnitRegistry")
	_check("village loaded with its villagers once, not twice", registry.count_alive(UnitRegistry.Kind.NPC, UnitRegistry.NEUTRAL_TEAM) == villagers)
	var innkeeper: NeutralSpawn = map.get_node("Villagers/Innkeeper")
	_check("innkeeper's handle still talks", registry.dialogue_of(innkeeper.handle) != null)

	# Walk back through the exit
	commander = map.get_node("Commander")
	var exit: Node3D = map.get_node("ToLane")
	for i in commander.heroes.size():  # the whole party, for 5 s
		registry.unit_of(commander.heroes[i]).teleport(exit.global_position + Vector3(i * 0.9 - 0.9, 0, 0))
	await create_timer(6.5).timeout
	await support.call(&"scene_changed", self, map)
	map = current_scene
	_check("the exit took the party back to the lane", map.scene_file_path.ends_with("main.tscn"))
	_check("the sword stays picked up on the lane", map.find_children("DroppedSword*", "", true, false).is_empty())
	commander = map.get_node("Commander")
	var lane_knight: Unit = (map.get_node("UnitRegistry") as UnitRegistry).unit_of(commander.heroes[0])
	_check("arrived at FromVillage", lane_knight.global_position.distance_to((map.get_node("FromVillage") as Node3D).global_position) < 4.0)

	# Online: only checkpoints
	campaign.online = true
	_check("online save refused off a checkpoint", not campaign.save_game("online").is_empty())
	campaign.online = false

	# Crash recovery: written quietly every RECOVERY_TIME of play, gone after a clean exit
	await create_timer(Campaign.RECOVERY_TIME + 1.0).timeout
	if campaign._recovery_task >= 0:
		WorkerThreadPool.wait_for_task_completion(campaign._recovery_task)
		campaign._recovery_task = -1
	var recovery: Array = campaign.list_saves().filter(func(h: Dictionary) -> bool: return h.slot == Campaign.RECOVERY_SLOT)
	_check("a crash-recovery save is written as the game goes on", recovery.size() == 1 and recovery[0].map.ends_with("main.tscn"))
	var leftovers := Array(DirAccess.get_files_at(Campaign.save_dir)).filter(func(f: String) -> bool: return f.ends_with(".part"))
	_check("no half-written save files left", leftovers.is_empty())
	var before_title := current_scene
	campaign.quit_to_title()
	await support.call(&"scene_changed", self, before_title)  # the title loads on a thread: let it finish
	_check("back to the title is a clean exit: the recovery save is gone",
			not campaign.list_saves().any(func(h: Dictionary) -> bool: return h.slot == Campaign.RECOVERY_SLOT))
	print("FAILURES: %d" % _failures)
	quit()


func _snapshot(map: Node) -> Dictionary:
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var commander: Commander = map.get_node("Commander")
	var party: PartyInventory = map.get_node("Party")
	var heroes := []
	for handle in commander.heroes:
		var unit := registry.unit_of(handle)
		heroes.append([handle, unit.definition.display_name, unit.level, snappedf(registry.health_of(handle), 0.1),
				snappedf(unit.mana, 0.1), unit.global_position.snappedf(0.1), unit.equipment.map(func(i: ItemDefinition) -> String: return i.display_name if i != null else "")])
	var rows := []
	var every := Array(registry.handles(-1) + registry.handles(-1, true))
	every.sort()  # by handle: the same order before and after a load
	for handle: int in every:
		rows.append([handle, registry.life_of(handle), registry.team_of(handle), snappedf(registry.health_of(handle), 0.1),
				registry.position_of(handle).snappedf(0.1)])
	var bag := party.bag.map(func(i: ItemDefinition) -> String: return i.display_name)
	return {
		"heroes": heroes,
		"rows": rows,
		"bag": bag,
		"combine": party.combine.map(func(i: ItemDefinition) -> String: return i.display_name if i != null else ""),
		"corpses": (map.get_node("Corpses") as CorpseField).count(),
		"selection": commander.control_selection.duplicate(),
		"group_2": commander._saved_sets[2].handles.duplicate(),
		"camera": (map.get_node("RTSCamera") as Node3D).position.snappedf(0.1),
		"skill_points": registry.unit_of(commander.heroes[0]).skill_points,
		"ability_levels": registry.unit_of(commander.heroes[0]).ability_levels,
	}


func _bag(party: PartyInventory, item_name: String) -> PartyInventory.Place:
	for i in party.bag.size():
		if party.bag[i].display_name == item_name:
			return PartyInventory.Place.new(PartyInventory.Area.BAG, i)
	return PartyInventory.Place.new(PartyInventory.Area.BAG, -1)


func _has(party: PartyInventory, item_name: String) -> bool:
	return party.bag.any(func(i: ItemDefinition) -> bool: return i.display_name == item_name)


func _equip(hero: Unit, index: int) -> PartyInventory.Place:
	return PartyInventory.Place.new(PartyInventory.Area.EQUIPMENT, index, hero)


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
