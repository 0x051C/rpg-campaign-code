extends SceneTree
## Maren and Brook, her bound water elemental (STORY.md): he's there from the start, follows her,
## his attacks chill and give her mana, he comes back when called, and survives a save.

var _failures := 0
var registry: UnitRegistry
var north: CreepSpawner


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var campaign := Campaign.current
	var scene: Node3D = support.call(&"open_map", self, ["maren"])
	registry = scene.get_node("UnitRegistry")
	north = scene.get_node("NorthSpawner")
	var commander: Commander = scene.get_node("Commander")
	await process_frame
	scene.get_node("CreepWaves").set("_next_wave_time", 999.0)
	await create_timer(1.0).timeout
	var maren := registry.unit_of(commander.heroes[0])
	var call_slot := _slot_of(maren, &"maren_call_brook")

	# From the start
	var brook := _brooks(maren)
	_check("Brook is there from the start", brook.size() == 1)
	if brook.is_empty():
		_finish()
		return
	var elemental: Unit = brook[0]
	_check("bound to Maren: a summon with no time limit", elemental.bound and elemental.is_summon()
			and elemental.lifetime == 0.0 and elemental.summoner == maren)
	_check("Call Brook known from level 1, the skill point still free", maren.ability_level(call_slot) == 1 and maren.skill_points == 1)
	_check("not one of the party's heroes", not commander.heroes.has(elemental.handle))

	# He follows her
	maren.teleport(Vector3(-20, 0, 30))
	elemental.teleport(Vector3(-5, 0, 30))
	await create_timer(5.0).timeout
	var gap := elemental.global_position.distance_to(maren.global_position)
	print("   Brook %.1f m from Maren after 5 s" % gap)
	_check("idle, he catches up with her", gap < Unit.COMPANION_FOLLOW + 1.5)

	# His attacks chill and give her mana
	maren.teleport(Vector3(0, 0, 14))
	elemental.teleport(Vector3(0, 0, 10))
	var skeleton := registry.spawn_npc(load("res://data/units/skeleton_warrior.tres"), 2, Vector3(0, 0, 5), north)
	registry.hold_position(skeleton)
	registry.set_max_health(skeleton, 5000.0)
	registry.set_health(skeleton, 5000.0)
	maren.mana = 0.0
	elemental.order_attack(skeleton, Unit.Queue.NONE)
	var chilled := false
	for i in 120:
		await Simulation.current.ticked
		if registry.attack_slow_of(skeleton) > 0.0:
			chilled = true
			break
	_check("a hit chills: 30% slower movement, 20% slower attacks", chilled
			and is_equal_approx(registry.slow_of(skeleton), 0.3) and is_equal_approx(registry.attack_slow_of(skeleton), 0.2))
	print("   Maren's mana after his first hit: %.1f" % maren.mana)
	_check("and gives Maren mana", maren.mana >= 3.0)
	elemental.order_stop()
	registry.kill(skeleton)

	# He falls; calling him brings him back
	registry.kill(elemental.handle)
	await create_timer(0.5).timeout
	_check("he can fall", _brooks(maren).is_empty())
	maren.mana = maren.max_mana
	maren.order_cast(call_slot, UnitRegistry.NONE, maren.global_position, Unit.Queue.NONE)
	await create_timer(1.5).timeout
	_check("Call Brook calls him back", _brooks(maren).size() == 1)

	# Called while he lives: he comes to her side, no second Brook
	elemental = _brooks(maren)[0]
	elemental.teleport(maren.global_position + Vector3(25, 0, 0))
	maren.ability_cooldowns[call_slot] = 0.0
	maren.order_cast(call_slot, UnitRegistry.NONE, maren.global_position, Unit.Queue.NONE)
	await create_timer(1.5).timeout
	_check("called while he lives, he returns to her side", _brooks(maren).size() == 1
			and elemental.global_position.distance_to(maren.global_position) < 4.0)
	maren.on_placed()  # arriving on a map again
	_check("arriving on a map doesn't make a second Brook", _brooks(maren).size() == 1)

	# A save keeps him bound to her
	_check("save", campaign.save_game("brook").is_empty())
	campaign.load_game("brook")
	await support.call(&"scene_changed", self, scene)
	await create_timer(1.0).timeout
	registry = current_scene.get_node("UnitRegistry")
	commander = current_scene.get_node("Commander")
	maren = registry.unit_of(commander.heroes[0])
	var loaded := _brooks(maren)
	_check("after loading, Brook is still hers", loaded.size() == 1 and loaded[0].summoner == maren
			and loaded[0].definition.attack_effect is ChillingAttack)
	campaign.delete_save("brook")
	_finish()


func _finish() -> void:
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _brooks(maren: Unit) -> Array[Unit]:
	var found: Array[Unit] = []
	for unit in registry.unit_nodes():
		if unit.bound and unit.summoner == maren and unit.is_alive():
			found.append(unit)
	return found


func _slot_of(unit: Unit, id: StringName) -> int:
	for slot in unit.definition.abilities.size():
		if unit.definition.abilities[slot].id() == id:
			return slot
	return -1


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
