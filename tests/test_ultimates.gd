extends SceneTree
## The ultimates reworked for hordes (DIRECTION.md 6): the Knight's Wrath of the Vigil (more damage,
## blows cleave), Maren's Pearl of the Deep (enemies around it entranced and drawn in, waves breaking
## over them), RWBY's Reflection (her blows and her illusion's split through their victims, 1-2-3 ways).

var _failures := 0
var registry: UnitRegistry
var spawner: CreepSpawner
var skeleton: UnitDefinition = load("res://data/units/skeleton_warrior.tres")


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var map: Node3D = support.call(&"open_map", self, ["maren", "knight", "ranger"], "res://scenes/maps/story_template.tscn")
	await create_timer(0.5).timeout
	registry = map.get_node("UnitRegistry")
	var commander: Commander = map.get_node("Commander")
	var maren := registry.unit_of(commander.heroes[0])
	var knight := registry.unit_of(commander.heroes[1])
	var rwby := registry.unit_of(commander.heroes[2])
	spawner = CreepSpawner.new()
	spawner.team = 2
	spawner.active = false
	map.add_child(spawner)
	for hero in [maren, knight, rwby]:
		hero.teleport(Vector3(-20, 0, 20))

	# Wrath of the Vigil
	knight.teleport(Vector3(0, 0, 0))
	var wrath: AbilityDefinition = knight.definition.abilities[3]
	_check("the Knight's ultimate is Wrath of the Vigil", wrath.display_name == "Wrath of the Vigil" and wrath.ultimate)
	var damage := knight.attack_damage()
	wrath.cast(_spell(knight, wrath, 1, knight.handle, Vector3.ZERO))
	_check("Wrath: her blows land much harder", is_equal_approx(knight.attack_damage(), damage * (1.0 + wrath.value(&"damage_bonus", 1) / 100.0)))
	var victim := _spawn(Vector3(0, 0, -2))
	var beside := _spawn(Vector3(1.5, 0, -3))
	var far := _spawn(Vector3(9, 0, -9))
	await process_frame
	var beside_before := registry.health_of(beside)
	var far_before := registry.health_of(far)
	knight.call(&"_attack_landed", victim, Callable(), 100.0)
	_check("Wrath: a blow cleaves into the enemies around its target", beside_before - registry.health_of(beside) >= 100.0 * wrath.value(&"cleave", 1) / 100.0 - 0.1
			and is_equal_approx(registry.health_of(far), far_before))
	for handle in [victim, beside, far]:
		registry.kill(handle)

	# Reflection's blades
	rwby.teleport(Vector3(12, 0, 12))  # the template map is 48 m across: keep inside
	var reflection: AbilityDefinition = rwby.definition.abilities[3]
	reflection.cast(_spell(rwby, reflection, 3, UnitRegistry.NONE, rwby.global_position))
	await process_frame
	var illusions: Array[Unit] = []
	for unit in registry.unit_nodes():
		if unit != rwby and unit.lifetime > 0.0 and unit.team == rwby.team and unit.definition.display_name == rwby.definition.display_name:
			illusions.append(unit)
	_check("Reflection: an illusion beside her", illusions.size() == 1)
	var target := _spawn(Vector3(12, 0, 9))  # straight ahead of her
	var behind := _spawn(Vector3(12, 0, 5))  # on the middle blade
	var left := _spawn(Vector3(9.9, 0, 5.4))  # on a fanned-out blade
	var aside := _spawn(Vector3(18, 0, 11))  # on none of them
	await process_frame
	var healths := [registry.health_of(behind), registry.health_of(left), registry.health_of(aside)]
	rwby.call(&"_attack_landed", target, Callable(), 100.0)
	_check("level 3: the blow passes through along three blades", registry.health_of(behind) < healths[0]
			and registry.health_of(left) < healths[1] and is_equal_approx(registry.health_of(aside), healths[2]))
	_check("and her illusion's blows split too", not illusions.is_empty() and not (illusions[0].get(&"_split") as Dictionary).is_empty())
	for handle in [target, behind, left, aside]:
		registry.kill(handle)

	# Pearl of the Deep
	maren.teleport(Vector3(-10, 0, 0))
	var pearl: AbilityDefinition = maren.definition.abilities[3]
	_check("Maren's ultimate is Pearl of the Deep", pearl.display_name == "Pearl of the Deep" and pearl.ultimate)
	var center := Vector3(-10, 0, -8)
	var around: Array[int] = []
	for i in 4:
		around.append(_spawn(center + Vector3(cos(TAU * i / 4.0), 0, sin(TAU * i / 4.0)) * 5.0))
	await process_frame
	var distances := around.map(func(h: int) -> float: return registry.position_of(h).distance_to(center))
	var before := around.map(func(h: int) -> float: return registry.health_of(h))
	maren.mana = 0.0
	maren.teleport(center + Vector3(0, 0, 3))
	pearl.cast(_spell(maren, pearl, 1, UnitRegistry.NONE, center))
	await create_timer(1.0).timeout
	var entranced := around.all(func(h: int) -> bool: return registry.is_stunned(h))
	var closer := true
	var hurt := true
	for i in around.size():
		closer = closer and registry.position_of(around[i]).distance_to(center) < distances[i] - 0.5
		hurt = hurt and registry.health_of(around[i]) < before[i]
	_check("the Pearl: enemies around it entranced", entranced)
	_check("drawn in towards it", closer)
	_check("and a wave broke over them", hurt)
	_check("its light gives Maren mana", maren.mana > 0.0)
	await create_timer(pearl.value(&"duration", 1) + 0.5).timeout
	_check("then it sinks: no longer entranced", not around.any(func(h: int) -> bool: return registry.is_alive(h) and registry.is_stunned(h)))

	# Divine Shield breaks outwards
	knight.teleport(Vector3(0, 0, 0))
	var shield: AbilityDefinition = knight.definition.abilities[1]
	var undead := _spawn(Vector3(1.5, 0, 1.5))
	await process_frame
	var undead_before := registry.health_of(undead)
	shield.cast(_spell(knight, shield, 1, UnitRegistry.NONE, Vector3.ZERO))
	await create_timer(shield.value(&"shield_duration", 1) + 0.4).timeout
	_check("Divine Shield: when it breaks, the light sears the undead around her",
			not registry.is_alive(undead) or undead_before - registry.health_of(undead) >= shield.value(&"end_burst", 1) * 2.0 - 0.1)
	if registry.is_alive(undead):
		registry.kill(undead)
	await _explosion_and_marks(map, commander)
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


## Explosion (the hidden staff's), and the Rogue's shadow marks: a second map with them.
func _explosion_and_marks(map: Node3D, _commander: Commander) -> void:
	var support: Script = load("res://tests/framework/support.gd")
	map.queue_free()
	await process_frame
	var second: Node3D = support.call(&"open_map", self, ["mage", "rogue_hero"], "res://scenes/maps/story_template.tscn")
	await create_timer(0.5).timeout
	registry = second.get_node("UnitRegistry")
	var commander: Commander = second.get_node("Commander")
	var mage := registry.unit_of(commander.heroes[0])
	var rogue := registry.unit_of(commander.heroes[1])
	spawner = CreepSpawner.new()
	spawner.team = 2
	spawner.active = false
	second.add_child(spawner)
	mage.teleport(Vector3(0, 0, 14))
	rogue.teleport(Vector3(-15, 0, 15))

	# Explosion: a chant, the blast, enemies knocked down, and she collapses
	var staff: ItemDefinition = load("res://data/items/crimson_demons_staff.tres")
	var explosion: AbilityDefinition = staff.ability
	_check("Explosion is the Crimson Demon's Staff's, hidden away; the Mage's ultimate is the Pearl, like Maren's",
			explosion.display_name == "Explosion" and mage.definition.abilities[3].display_name == "Pearl of the Deep")
	var crowd: Array[int] = []
	for i in 6:
		crowd.append(_spawn(Vector3(cos(TAU * i / 6.0), 0, sin(TAU * i / 6.0)) * 4.0))
	var outside := _spawn(Vector3(16, 0, -16))
	await process_frame
	var spell := _spell(mage, explosion, 1, UnitRegistry.NONE, Vector3.ZERO)
	explosion.cast(spell)
	explosion.end_channel(spell, false)
	var blasted := crowd.all(func(h: int) -> bool: return not registry.is_alive(h) or registry.is_stunned(h))
	_check("Explosion: the crowd is blasted and knocked down", blasted and registry.health_of(outside) == registry.max_health_of(outside))
	_check("and she collapses", registry.is_stunned(mage.handle))
	var interrupted := _spell(mage, explosion, 1, UnitRegistry.NONE, Vector3(16, 0, -16))
	explosion.end_channel(interrupted, true)
	_check("interrupted, nothing goes off", registry.health_of(outside) == registry.max_health_of(outside))
	for handle in crowd + [outside]:
		if registry.is_alive(handle):
			registry.kill(handle)

	# Swift Slashes' shadow marks burst after the slashes
	rogue.teleport(Vector3(-15, 0, 15))
	var slashes: AbilityDefinition = rogue.definition.abilities[3]
	var struck := _spawn(Vector3(-15, 0, 10))
	var bystander := _spawn(Vector3(-13, 0, 9))
	await process_frame
	var slash := _spell(rogue, slashes, 1, struck, registry.position_of(struck))
	slash.data["marks"] = {struck: {"damage": 200.0, "at": registry.position_of(struck)}}
	var bystander_before := registry.health_of(bystander)
	slashes.end_channel(slash, false)
	_check("a mark doesn't burst at once", is_equal_approx(registry.health_of(bystander), bystander_before))
	await create_timer(slashes.value(&"mark_delay", 1) + 0.4).timeout
	_check("Swift Slashes: the mark bursts onto the enemies around it",
			bystander_before - registry.health_of(bystander) >= 200.0 * slashes.value(&"mark_share", 1) / 100.0 - 0.1)


func _spawn(at: Vector3) -> int:
	return registry.spawn_npc(skeleton, 2, at, spawner)


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
