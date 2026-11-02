extends SceneTree
## Creep spawners send Heracles (NoH Legionnaire's spells, computer-controlled) instead of
## siege creeps. OUT=<prefix> for screenshots.

var _out := OS.get_environment("OUT")
var _failures := 0
var registry: UnitRegistry
var north: CreepSpawner
var south: CreepSpawner


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	Campaign.current.flags = {}
	var scene: Node3D = load("res://scenes/main.tscn").instantiate()
	var party: Array[UnitDefinition] = [load("res://data/units/knight.tres"), load("res://data/units/mage.tres"), load("res://data/units/rogue_hero.tres")]
	scene.set("starting_party", party)
	root.add_child(scene)
	current_scene = scene
	var camera: RTSCamera = scene.get_node("RTSCamera")
	camera.edge_scroll = false
	registry = scene.get_node("UnitRegistry")
	north = scene.get_node("NorthSpawner")
	south = scene.get_node("SouthSpawner")
	var commander: Commander = scene.get_node("Commander")
	var waves: CreepWaves = scene.get_node("CreepWaves")
	await process_frame
	waves.set("_next_wave_time", 9999.0)
	await create_timer(1.0).timeout
	var heroes: Array[Unit] = []
	for handle in commander.heroes:
		heroes.append(registry.unit_of(handle))
	heroes[0].level = 6
	for hero in heroes:
		hero.teleport(Vector3(-30 + heroes.find(hero) * 3, 0, 40))  # out of the way

	# A siege wave: each spawner sends Heracles instead of siege creeps
	var siege_before := _count_siege()
	waves.wave_count = 10
	waves.spawn_wave()
	await create_timer(0.3).timeout
	var enemy := registry.unit_of(north.hero_handle)
	var ally := registry.unit_of(south.hero_handle)
	_check("both spawners sent a Heracles", enemy != null and ally != null and enemy.definition.display_name == "Heracles")
	_check("no siege creeps came with them", _count_siege() == siege_before)
	_check("at the party's best level (6), spells learned", enemy.level == 6 and enemy.skill_points == 0
			and enemy.ability_level(3) == 1)
	print("   levels: Taunt %d, Charge %d, Whirling Blade %d, Decapitate %d" % [enemy.ability_level(0), enemy.ability_level(1), enemy.ability_level(2), enemy.ability_level(3)])
	_check("the party's heroes still count 3", commander.heroes.size() == 3)
	_check("the allied Heracles can't be commanded", not commander.can_command(ally.handle))
	waves.wave_count = 20
	waves.spawn_wave()
	await create_timer(0.2).timeout
	_check("no second Heracles while the first lives", registry.unit_of(north.hero_handle) == enemy)

	# He walks the lane
	registry.unit_of(south.hero_handle).teleport(Vector3(40, 0, 60))  # the ally waits aside
	ally.ai = false  # (stop its brain from walking back) - keep it out of the tests
	ally.brain.queue_free()
	var start := enemy.global_position
	await create_timer(3.0).timeout
	print("   enemy Heracles walked %.1f m down the lane" % start.distance_to(enemy.global_position))
	_check("the enemy Heracles walks its lane", enemy.global_position.z > start.z + 5.0)
	_check("hidden by the fog while nobody sees him", enemy._visual.visible == registry.player_sees(enemy.handle))

	# Taunt: three allied creeps and the Knight around him
	for unit in registry.unit_nodes():
		if unit != enemy and unit != ally and unit.team == 2:
			pass
	var spot := enemy.global_position
	var knight := heroes[0]
	knight.teleport(spot + Vector3(2.5, 0, 0))
	var creeps: Array[int] = []
	for i in 3:
		creeps.append(_spawn(south, spot + Vector3(-2 + i * 2, 0, 2.5)))
	enemy.mana = enemy.max_mana
	await create_timer(1.0).timeout
	camera.center_on(spot)
	_check("he taunts the crowd: the Knight is forced to attack him", knight._taunt_time > 0.0
			and not knight.orders.is_empty() and knight.orders[0].target == enemy.handle)
	knight.order_move(spot + Vector3(10, 0, 0), Unit.Queue.NONE)
	_check("a taunted hero ignores orders and can't cast", knight.orders[0].type == UnitOrder.Type.ATTACK
			and knight.ability_error(0) == "Taunted")
	_check("taunted creeps attack him", creeps.all(func(c: int) -> bool: return not registry.is_alive(c) or registry.target_of(c) == enemy.handle))
	await _shot("taunt")

	# Whirling Blade: a 17% chance per attack, damage to everyone around
	var whirl_slot := 2
	var procs := 0
	for i in 200:
		enemy.ability_cooldowns[whirl_slot] = 0.0
		enemy.on_attacked(knight.handle)
		if enemy.ability_cooldowns[whirl_slot] > 0.0:
			procs += 1
	print("   Whirling Blade went off %d times in 200 attacks (17%%: about 34)" % procs)
	_check("Whirling Blade goes off about 17% of the time", procs > 15 and procs < 60)
	for c in creeps:
		if registry.is_alive(c):
			registry.kill(c)

	# Decapitate: the Knight below 300 health dies outright
	await create_timer(3.5).timeout  # the taunt ends
	registry.set_health(knight.handle, 250.0)
	enemy.mana = enemy.max_mana
	enemy.ability_cooldowns[3] = 0.0
	await create_timer(1.5).timeout
	_check("Decapitate kills the Knight below 300 health", not knight.is_alive())
	await _shot("decapitate")
	knight.revive(1.0)

	# Charge: the Rogue 15 m away gets charged, struck and terrified
	var rogue := heroes[2]
	rogue.teleport(enemy.global_position + Vector3(0, 0, 15))
	knight.teleport(Vector3(-30, 0, 40))
	registry.set_max_health(rogue.handle, 5000.0)
	registry.set_health(rogue.handle, 5000.0)
	enemy.mana = enemy.max_mana
	enemy.ability_cooldowns[1] = 0.0
	var rogue_health := registry.health_of(rogue.handle)
	var charged := false
	var landed := false
	for i in 400:
		await physics_frame
		if not enemy._charge.is_empty():
			charged = true
		elif charged:
			landed = true
			break
	await physics_frame
	print("   distance after the charge: %.1f m, Rogue health %.0f -> %.0f" % [enemy.global_position.distance_to(rogue.global_position), rogue_health, registry.health_of(rogue.handle)])
	_check("he charges the Rogue", charged and landed)
	_check("and strikes her: she's terrified (half damage)", registry.health_of(rogue.handle) < rogue_health
			and is_equal_approx(registry.attack_damage(rogue.handle, 10.0), 5.0))
	await _shot("charge")

	# Save and load with Heracles alive
	_check("save", Campaign.current.save_game("heracles").is_empty())
	Campaign.current.load_game("heracles")
	await Campaign.current.loaded
	await create_timer(0.5).timeout
	scene = current_scene
	registry = scene.get_node("UnitRegistry")
	north = scene.get_node("NorthSpawner")
	commander = scene.get_node("Commander")
	enemy = registry.unit_of(north.hero_handle)
	_check("after loading he's back, computer-controlled, on his lane", enemy != null and enemy.ai and enemy.brain != null
			and enemy.brain.spawner == north and commander.heroes.size() == 3)

	# Death: the party gets experience, the body fades, the next siege wave sends another
	var party_xp := 0.0
	for handle in commander.heroes:
		var hero := registry.unit_of(handle)
		hero.teleport(enemy.global_position + Vector3(3, 0, 0))
		party_xp += hero.experience
	await process_frame
	registry.apply_damage(enemy.handle, 99999.0, commander.heroes[1], false)
	var gained := 0.0
	for handle in commander.heroes:
		gained += registry.unit_of(handle).experience
	_check("killing him gives the party experience", gained > party_xp)
	await create_timer(Unit.AI_CORPSE_TIME + 2.0).timeout
	_check("his body fades and leaves the registry", not is_instance_valid(enemy) and not registry.is_alive(north.hero_handle))
	var waves2: CreepWaves = scene.get_node("CreepWaves")
	waves2.wave_count = 30
	waves2.spawn_wave()
	await create_timer(0.3).timeout
	_check("the next siege wave sends a new Heracles", registry.unit_of(north.hero_handle) != null)
	print("FAILURES: %d" % _failures)
	quit()


func _count_siege() -> int:
	var count := 0
	for handle in registry.handles(UnitRegistry.Kind.NPC):
		if registry.definition_of(handle) == north.siege:
			count += 1
	return count


func _spawn(spawner: CreepSpawner, at: Vector3) -> int:
	var handle := registry.spawn_npc(spawner.melee, spawner.team, at, spawner)
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
