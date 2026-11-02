extends SceneTree
## The story's recruits' kits (STORY.md 6): Tamsin's Burning Arrows (an attack modifier and an aura),
## Seeking Arrows on every spell, the Hawk (a line strike, rescue when low, a scout at level 3), her
## reach growing with Strength; Ser Aldith's Holy Light healing a friend and searing the undead around.

var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var map: Node3D = support.call(&"open_map", self, ["story/tamsin", "story/aldith"], "res://scenes/maps/story_template.tscn")
	await create_timer(0.5).timeout
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var commander: Commander = map.get_node("Commander")
	var tamsin := registry.unit_of(commander.heroes[0])
	var aldith := registry.unit_of(commander.heroes[1])
	tamsin.teleport(Vector3(0, 0, 0))
	aldith.teleport(Vector3(-3, 0, 0))
	var spawner := CreepSpawner.new()
	spawner.team = 2
	spawner.active = false
	map.add_child(spawner)
	var skeleton: UnitDefinition = load("res://data/units/skeleton_warrior.tres")

	# Her reach grows with Strength (Eagle Eye)
	var reach := tamsin.attack_range()
	var strength := tamsin.stats.value(Stats.Stat.STRENGTH)
	_check("Eagle Eye: Strength reaches farther", reach > tamsin.definition.attack_range
			and is_equal_approx(reach - tamsin.definition.attack_range, strength * 0.05))

	# Burning Arrows: an aura for the party's ranged attacks while she knows it
	tamsin.level = 6
	tamsin.skill_points = 6
	for slot in 4:
		tamsin.learn(slot)
	_check("she learns all four (the Hawk at 6)", tamsin.ability_level(0) == 1 and tamsin.ability_level(2) == 1 and tamsin.ability_level(3) == 1)
	var auras := tamsin.active_auras()
	_check("Burning Arrows is also an aura (Trueshot)", auras.any(func(a: Dictionary) -> bool:
			return (a.ability as AbilityDefinition).display_name == "Burning Arrows"))

	# The Hawk strikes along its line; Seeking Arrows answer the spell
	var line: Array[int] = []
	for i in 3:
		line.append(registry.spawn_npc(skeleton, 2, Vector3(0, 0, -4.0 - i * 3.0), spawner))
	var aside := registry.spawn_npc(skeleton, 2, Vector3(9, 0, -6), spawner)
	await process_frame
	var before: Array[float] = []
	for handle in line:
		before.append(registry.health_of(handle))
	var aside_before := registry.health_of(aside)
	tamsin.mana = tamsin.max_mana
	var hawk_slot := 3
	var spell := _spell(tamsin, tamsin.definition.abilities[hawk_slot], 1, UnitRegistry.NONE, Vector3(0, 0, -14))
	tamsin.definition.abilities[hawk_slot].cast(spell)
	var struck := 0
	for i in line.size():
		struck += 1 if registry.health_of(line[i]) < before[i] else 0
	_check("the Hawk strikes everything in its path, not beside it", struck == 3 and is_equal_approx(registry.health_of(aside), aside_before))
	var seeking: AbilityDefinition = tamsin.definition.abilities[2]
	var shots := root.find_children("*", "Projectile", true, false).size()
	seeking.on_owner_cast(tamsin, 1, tamsin.definition.abilities[hawk_slot])
	_check("Seeking Arrows: a spell looses its arrows at the nearest enemies",
			root.find_children("*", "Projectile", true, false).size() >= shots + int(seeking.value(&"arrows", 1)))

	# The Hawk comes for her when she's low, once in a while
	registry.set_health(tamsin.handle, registry.max_health_of(tamsin.handle) * 0.2)
	var low := registry.health_of(tamsin.handle)
	tamsin.on_damaged(UnitRegistry.NONE)
	_check("low: the hawk heals her", registry.health_of(tamsin.handle) > low + 150.0)
	registry.set_health(tamsin.handle, low)
	tamsin.on_damaged(UnitRegistry.NONE)
	_check("but not again at once", is_equal_approx(registry.health_of(tamsin.handle), low))

	# Hawkeye Bracers: it flies back through the line
	var bracers: ItemDefinition = load("res://data/items/legendary/hawkeye_bracers.tres")
	tamsin.equipment[Equipment.place_for(tamsin.equipment, bracers)] = bracers
	tamsin.recalculate_stats()
	registry.set_health(tamsin.handle, registry.max_health_of(tamsin.handle))
	var prey := registry.spawn_npc(skeleton, 2, Vector3(0, 0, -8), spawner)
	await process_frame
	var prey_before := registry.health_of(prey)
	var there := _spell(tamsin, tamsin.definition.abilities[hawk_slot], 1, UnitRegistry.NONE, Vector3(0, 0, -14))
	tamsin.definition.abilities[hawk_slot].cast(there)
	for power in tamsin.worn_powers():
		power.on_cast(tamsin, tamsin.definition.abilities[hawk_slot], there)
	var once := prey_before - registry.health_of(prey)
	await create_timer(1.0).timeout
	_check("Hawkeye Bracers: the hawk comes back through the line, striking again",
			once > 0.0 and prey_before - registry.health_of(prey) > once * 1.5 or not registry.is_alive(prey))

	# At level 3 it stays to scout
	var level3 := _spell(tamsin, tamsin.definition.abilities[hawk_slot], 3, UnitRegistry.NONE, Vector3(20, 0, 20))
	tamsin.definition.abilities[hawk_slot].cast(level3)
	await create_timer(0.3).timeout
	var hawks := registry.unit_nodes().filter(func(u: Unit) -> bool: return u.definition.display_name == "Tamsin's hawk")
	_check("level 3: the hawk stays where it lands, for a while", hawks.size() == 1 and (hawks[0] as Unit).lifetime > 0.0
			and (hawks[0] as Unit).global_position.distance_to(Vector3(20, 0, 20)) < 3.0)

	# Ser Aldith's Holy Light: heals a friend, sears the undead around it, twice as hard as the living
	for handle in line + [aside]:
		if registry.is_alive(handle):
			registry.kill(handle)
	var undead := registry.spawn_npc(skeleton, 2, Vector3(1, 0, 1), spawner)
	var far := registry.spawn_npc(skeleton, 2, Vector3(25, 0, -25), spawner)
	await process_frame
	registry.set_health(tamsin.handle, 100.0)
	var undead_before := registry.health_of(undead)
	var far_before := registry.health_of(far)
	var light: AbilityDefinition = aldith.definition.abilities[0]
	var cast := _spell(aldith, light, 1, tamsin.handle, Vector3.ZERO)
	_check("Holy Light: a friend is a fine target, an enemy isn't", light.check_target(cast, tamsin.handle).is_empty()
			and not light.check_target(cast, undead).is_empty())
	light.cast(cast)
	_check("Holy Light heals the friend", registry.health_of(tamsin.handle) > 100.0 + 150.0)
	_check("and sears the undead around it, twice over (and her spell damage on top)",
			undead_before - registry.health_of(undead) >= light.value(&"sear_damage", 1) * 2.0 - 0.1 or not registry.is_alive(undead))
	_check("not the ones far away", is_equal_approx(registry.health_of(far), far_before))
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _spell(caster: Unit, ability: AbilityDefinition, level: int, target: int, point: Vector3) -> SpellCast:
	var spell := SpellCast.new()
	spell.caster = caster
	spell.ability = ability
	spell.level = level
	spell.registry = caster.registry
	spell.target = target
	spell.point = point
	return spell


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
