extends SceneTree
## The developer console (scripts/debug/dev_console.gd): every command does what it says on a real map, presets
## run, and Tab completion offers the right names.

var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var map: Node3D = support.call(&"open_map", self, ["maren", "brook"], "res://scenes/maps/prologue.tscn")
	await create_timer(1.0).timeout
	var console := DevConsole.current
	_check("the console is up (a debug build)", console != null)
	console.run("skip")
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var party: PartyInventory = map.get_node("Party")
	var maren := party.heroes()[0]

	console.run("gold 50")
	_check("gold sets", party.gold == 50)
	console.run("gold +25; gold -5")
	_check("gold adds and takes, two commands on a line", party.gold == 70)

	console.run("level 4")
	_check("level raises the heroes, with skill points", maren.level == 4 and maren.skill_points >= 4)
	var points := maren.skill_points
	console.run("points 2")
	_check("points gives skill points", maren.skill_points == points + 2)

	var bag := party.bag.size()
	console.run("give lightbrand")
	_check("give puts a named item in the bag", party.bag.size() == bag + 1 and party.bag.back().display_name == "Lightbrand")
	console.run("give leather_cap rare 5")
	var rolled: ItemDefinition = party.bag.back()
	_check("give with a rarity rolls it", rolled.rarity == ItemDefinition.Rarity.RARE and rolled.item_level == 5)
	console.run("loot 3 legendary")
	_check("loot rolls a legendary", (party.bag.back() as ItemDefinition).rarity == ItemDefinition.Rarity.LEGENDARY)

	var at := maren.global_position + Vector3(4, 0, 0)
	(map.get_node("Commander") as Commander).trace_position = at  # where the mouse points
	console.run("spawn skeleton_minion 3")
	await process_frame
	var enemies := _enemies(registry)
	_check("spawn puts enemies at the cursor", enemies.size() >= 3 and enemies.any(func(h: int) -> bool:
			return registry.position_of(h).distance_to(at) < 3.0))

	console.run("god")
	var before := registry.health_of(maren.handle)
	registry.apply_damage(maren.handle, 100.0, enemies[0], false, false)
	_check("god mode: the party takes no damage", is_equal_approx(registry.health_of(maren.handle), before))
	console.run("god")
	registry.apply_damage(maren.handle, 100.0, enemies[0], false, false)
	_check("and off again it does", registry.health_of(maren.handle) < before)
	maren.mana = 0.0
	console.run("heal")
	_check("heal fills health and mana", is_equal_approx(registry.health_of(maren.handle), registry.max_health_of(maren.handle))
			and is_equal_approx(maren.mana, maren.max_mana))
	maren.ability_cooldowns.fill(9.0)
	console.run("refresh")
	_check("refresh ends the cooldowns", Array(maren.ability_cooldowns).all(func(c: float) -> bool: return c == 0.0))

	console.run("killall")
	await process_frame
	_check("killall leaves no enemy", _enemies(registry).is_empty())

	console.run("flag console_test; flags")
	_check("flag sets a story flag", Campaign.current.has_story_flag(&"console_test"))
	console.run("flag console_test 0")
	_check("and 0 clears it", not Campaign.current.has_story_flag(&"console_test"))

	var quest := map.find_child("TheBrokenRoad", true, false) as Quest
	var first := quest.current
	console.run("step")
	console.run("skip")
	_check("step completes the current quest step", quest.current != first)

	(map.get_node("Commander") as Commander).trace_position = at  # the commander re-traces the mouse every frame
	console.run("tp")
	_check("tp moves the party to the cursor", maren.global_position.distance_to(at) < 2.5)
	console.run("fog")
	_check("fog toggles the fog of war", not FogOfWar.current.enabled)
	console.run("fog; tod dawn")
	_check("tod changes the time of day", Campaign.current.flags.get("time_of_day", {}).get(map.scene_file_path) == &"dawn")

	party.gold = 0
	console.run("exec vigil_ready")
	_check("exec runs a preset", party.gold == 40)

	_check("Tab: command names", console.call(&"_candidates", "gi") == PackedStringArray(["give"]))
	_check("Tab: units, folders too", (console.call(&"_candidates", "spawn creatures/og") as PackedStringArray).has("creatures/ogre"))
	_check("Tab: items", (console.call(&"_candidates", "give light") as PackedStringArray).has("lightbrand"))
	_check("Tab: maps", (console.call(&"_candidates", "map vi") as PackedStringArray).has("village")
			and (console.call(&"_candidates", "map vi") as PackedStringArray).has("vigil"))
	_check("Tab: presets", (console.call(&"_candidates", "exec vi") as PackedStringArray).has("vigil_ready"))
	_check("Tab: after a ;", console.call(&"_candidates", "heal; tim") == PackedStringArray(["time"]))
	console.run("time 1")
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _enemies(registry: UnitRegistry) -> Array[int]:
	var found: Array[int] = []
	for handle in registry.handles():
		if registry.is_alive(handle) and UnitRegistry.are_enemies(registry.team_of(handle), registry.player_team):
			found.append(handle)
	return found


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
