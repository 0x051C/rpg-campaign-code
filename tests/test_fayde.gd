extends SceneTree
## RWBY (the old Ranger) with NoH Fayde's spells: Cull, Burning Shadows, Shadow Stance,
## Reflection. OUT=<prefix> for screenshots.

var _out := OS.get_environment("OUT")
var _failures := 0
var registry: UnitRegistry
var north: CreepSpawner


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var scene: Node3D = load("res://scenes/main.tscn").instantiate()
	var party: Array[UnitDefinition] = [load("res://data/units/ranger.tres"), load("res://data/units/knight.tres"), load("res://data/units/mage.tres")]
	scene.set("starting_party", party)
	root.add_child(scene)
	current_scene = scene
	var camera: RTSCamera = scene.get_node("RTSCamera")
	camera.edge_scroll = false
	registry = scene.get_node("UnitRegistry")
	north = scene.get_node("NorthSpawner")
	var commander: Commander = scene.get_node("Commander")
	await process_frame
	scene.get_node("CreepWaves").set("_next_wave_time", 999.0)
	await create_timer(1.0).timeout
	var ruby := registry.unit_of(commander.heroes[0])
	for i in [1, 2]:
		registry.unit_of(commander.heroes[i]).teleport(Vector3(-40 + i * 3, 0, 60))
	var ids := ruby.definition.abilities.map(func(a: AbilityDefinition) -> StringName: return a.id())
	_check("renamed RWBY", ruby.definition.display_name == "RWBY")
	_check("Fayde's four spells", ids == [&"fayde_cull", &"fayde_burning_shadows", &"fayde_shadow_stance", &"fayde_reflection"])
	ruby.level = 7
	ruby.skill_points = 20
	for slot in 4:
		while ruby.can_learn(slot):
			ruby.learn(slot)
	_check("basic spells reach level 4 at hero level 7", ruby.ability_level(0) == 4 and ruby.ability_level(1) == 4)
	var home := Vector3(0, 0, 20)
	ruby.teleport(home)
	ruby.rotation.y = PI  # facing north (-Z)
	camera.center_on(home)

	# Cull: enemies within 7.3 m take 250 magic damage, the one outside doesn't
	var near := [_spawn(home + Vector3(2, 0, -2)), _spawn(home + Vector3(-4, 0, 3)), _spawn(home + Vector3(0, 0, -6))]
	var far := _spawn(home + Vector3(9, 0, 0))
	var before := near.map(func(h: int) -> float: return registry.health_of(h))
	ruby.mana = ruby.max_mana
	ruby.order_cast(0, UnitRegistry.NONE, ruby.global_position, Unit.Queue.NONE)
	await create_timer(0.5).timeout
	var dealt := []
	for i in near.size():
		dealt.append(before[i] - registry.health_of(near[i]) if registry.is_alive(near[i]) else before[i])
	print("   Cull dealt: %s; outside: %.0f/%.0f" % [dealt, registry.health_of(far), registry.max_health_of(far)])
	_check("Cull hits everyone within its radius", dealt.all(func(d: float) -> bool: return d >= 200.0))
	_check("Cull misses the one outside", is_equal_approx(registry.health_of(far), registry.max_health_of(far)))
	ruby.order_stop()
	for handle: int in near + [far]:
		if registry.is_alive(handle):
			registry.kill(handle)
	await create_timer(0.3).timeout

	# Burning Shadows: a line north; the two in it are stunned and bleed, the one beside isn't
	var in_line := [_spawn(home + Vector3(0.5, 0, -4)), _spawn(home + Vector3(-0.5, 0, -10))]
	var beside := _spawn(home + Vector3(6, 0, -6))
	for handle: int in in_line + [beside]:
		registry.hold_position(handle)
	ruby.mana = ruby.max_mana
	ruby.order_cast(1, UnitRegistry.NONE, home + Vector3(0, 0, -8), Unit.Queue.NONE)
	await create_timer(0.75).timeout
	await _shot("burning_shadows")
	_check("Burning Shadows stuns both in its path", in_line.all(func(h: int) -> bool: return registry.is_stunned(h)))
	_check("the one beside it isn't", not registry.is_stunned(beside))
	ruby.teleport(home + Vector3(0, 0, 30))  # out of reach: only the bleed hurts them
	await create_timer(0.5).timeout  # a shot already flying at them lands first
	var bleeding := registry.health_of(in_line[0])
	var since := registry.now()
	await create_timer(0.8).timeout  # well inside the 4 s bleed
	var rate := (bleeding - registry.health_of(in_line[0])) / (registry.now() - since)  # timers overshoot at high speed
	var bleed := 55.0 * (1.0 + registry.spell_damage_of(ruby.handle) / 100.0)
	print("   bleed: %.1f a second (level 4: 55/s with her spell damage: %.1f)" % [rate, bleed])
	_check("they bleed 55 a second, raised by her spell damage", absf(rate - bleed) < 4.0)
	await create_timer(1.8).timeout
	_check("the 2.5 s stun wears off", not registry.is_stunned(in_line[0]))
	ruby.teleport(home)
	for handle: int in in_line + [beside]:
		if registry.is_alive(handle):
			registry.kill(handle)

	# Shadow Stance: a projectile already in flight misses; attacks miss for 3 s
	var archer := _spawn(home + Vector3(0, 0, -12))
	registry.hold_position(archer)
	var health := registry.health_of(ruby.handle)
	Projectile.launch(registry, archer, ruby.handle, 50.0, 8.0, Color.RED)
	await create_timer(0.2).timeout
	var speed := ruby.move_speed()
	ruby.mana = ruby.max_mana
	ruby.order_cast(2, UnitRegistry.NONE, ruby.global_position, Unit.Queue.NONE)
	await create_timer(0.1).timeout
	_check("Shadow Stance: 100% evasion", is_equal_approx(registry.evasion_of(ruby.handle), 100.0))
	_check("and 13% faster", absf(ruby.move_speed() / speed - 1.13) < 0.01)
	await create_timer(1.8).timeout
	_check("the projectile in flight missed", registry.health_of(ruby.handle) >= health - 0.01)
	await create_timer(1.5).timeout
	_check("evasion back to normal after 3 s", registry.evasion_of(ruby.handle) < 50.0)
	registry.kill(archer)

	# Reflection: illusion, stealth, crippling hits
	var victim := _spawn(home + Vector3(0, 0, -5))
	registry.hold_position(victim)
	registry.set_max_health(victim, 5000.0)
	registry.set_health(victim, 5000.0)
	ruby.mana = ruby.max_mana
	ruby.order_cast(3, UnitRegistry.NONE, ruby.global_position, Unit.Queue.NONE)
	await create_timer(0.2).timeout
	var illusions := registry.unit_nodes().filter(func(u: Unit) -> bool: return u.is_summon() and u.definition.model == ruby.definition.model)
	_check("Reflection leaves an illusion that takes 300% damage", illusions.size() == 1 and is_equal_approx(illusions[0].damage_taken, 3.0))
	_check("and hides her", ruby.is_stealthed() and registry.is_stealthed(ruby.handle))
	await _shot("reflection")
	ruby.order_attack(victim, Unit.Queue.NONE)
	await create_timer(1.6).timeout
	_check("the illusion fights on after her first hit, its blows splitting like hers (DIRECTION.md 6)",
			is_instance_valid(illusions[0]) and illusions[0].is_alive() and not (illusions[0].get(&"_split") as Dictionary).is_empty())
	var reflection := ruby.ability_at(3)
	var level := ruby.ability_level(3)
	_check("the target is crippled (%d%% slow at level %d)" % [reflection.value(&"cripple_slow", level), level],
			is_equal_approx(registry.slow_of(victim), reflection.value(&"cripple_slow", level) / 100.0))
	_check("attacking didn't reveal her", ruby.is_stealthed())
	await create_timer(1.67 * reflection.value(&"charges", level) + 1.0).timeout
	_check("out of charges (%d), she's visible again" % reflection.value(&"charges", level), not ruby.is_stealthed())
	print("FAILURES: %d" % _failures)
	quit()


func _spawn(at: Vector3) -> int:
	var handle := registry.spawn_npc(load("res://data/units/skeleton_minion.tres"), 2, at, north)
	registry.hold_position(handle)
	return handle


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _shot(shot_name: String) -> void:
	if _out.is_empty():
		return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("%s_%s.png" % [_out, shot_name])
