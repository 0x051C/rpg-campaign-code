extends SceneTree
## The anime heroes' own clips and voices: every active spell plays its clip (and channel
## clip), Searing Arrows its attack, Swift Slashes a punch per strike, attacks alternate,
## orders and spells get spoken lines. PARTY="knight mage ranger" (unit files), OUT=<prefix>.

var _out := OS.get_environment("OUT")
var _failures := 0
var registry: UnitRegistry
var north: CreepSpawner
var commander: Commander

const EXPECTED := {  # ability id: [clip during the cast, clip while channeling or striking]
	&"paladin_holy_light": [&"abilities/paladin_holy_light", &""],
	&"paladin_divine_shield": [&"abilities/paladin_divine_shield", &""],
	&"paladin_resurrection": [&"abilities/paladin_resurrection", &""],
	&"paladin_wrath_of_the_vigil": [&"abilities/paladin_wrath_of_the_vigil", &""],
	&"maren_pearl_of_the_deep": [&"abilities/maren_pearl_of_the_deep", &""],
	&"archmage_blizzard": [&"abilities/archmage_blizzard", &"abilities/archmage_blizzard_channel"],
	&"archmage_summon_water_elemental": [&"abilities/archmage_summon_water_elemental", &""],
	&"archmage_mass_teleport": [&"abilities/archmage_mass_teleport", &"abilities/archmage_mass_teleport_channel"],
	&"megumin_explosion": [&"abilities/megumin_explosion", &"abilities/megumin_explosion_channel"],
	&"fayde_cull": [&"abilities/fayde_cull", &""],
	&"fayde_burning_shadows": [&"abilities/fayde_burning_shadows", &""],
	&"fayde_shadow_stance": [&"abilities/fayde_shadow_stance", &""],
	&"fayde_reflection": [&"abilities/fayde_reflection", &""],
	&"rogue_vanish": [&"abilities/rogue_vanish", &""],
	&"rogue_eviscerate": [&"abilities/rogue_eviscerate", &""],
	&"rogue_riposte": [&"abilities/rogue_riposte", &""],
	&"rogue_swift_slashes": [&"abilities/rogue_swift_slashes", &"abilities/rogue_swift_slashes_strike"],
}


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var scene: Node3D = load("res://scenes/main.tscn").instantiate()
	var party: Array[UnitDefinition] = []
	for unit_name in OS.get_environment("PARTY").split(" ", false):
		party.append(load("res://data/units/%s.tres" % unit_name))
	scene.set("starting_party", party)
	root.add_child(scene)
	current_scene = scene
	var camera: RTSCamera = scene.get_node("RTSCamera")
	camera.edge_scroll = false
	registry = scene.get_node("UnitRegistry")
	north = scene.get_node("NorthSpawner")
	commander = scene.get_node("Commander")
	await process_frame
	scene.get_node("CreepWaves").set("_next_wave_time", 999.0)
	await create_timer(1.0).timeout
	var heroes: Array[Unit] = []
	for handle in commander.heroes:
		heroes.append(registry.unit_of(handle))

	var leader_voice: HeroVoice = heroes[0]._voice
	_check("%s greets a new game" % heroes[0].definition.display_name, leader_voice == null or leader_voice.voice.spawn.is_empty()
			or leader_voice.voice.spawn.has(leader_voice.stream))
	_quiet(heroes)

	for i in heroes.size():
		var hero := heroes[i]
		var spot := Vector3(-10 + i * 10, 0, 20)
		for other in heroes:
			if other != hero:
				other.teleport(Vector3(-40 + heroes.find(other) * 3, 0, 60))
		hero.teleport(spot)
		camera.center_on(spot)
		hero.level = 6
		hero.skill_points = 10
		for slot in Unit.HERO_ABILITY_SLOTS:
			while hero.can_learn(slot):
				hero.learn(slot)
		print("== %s (%s)" % [hero.definition.display_name, hero.definition.model.resource_path.get_file()])

		# Attacks alternate between the model's attack clips
		var dummy := _spawn("skeleton_warrior", spot + Vector3(0, 0, -1.6))
		registry.set_invulnerable(dummy, true)
		var attack_clips := {}
		hero.order_attack(dummy, Unit.Queue.NONE)
		for step in 120:  # about ten swings: two variants picked at random both show (with 60 steps, one in eight runs saw only one)
			await create_timer(0.1).timeout
			if hero._swing_time >= 0.0:
				attack_clips[hero._anim.current_animation] = true
		hero.order_stop()
		attack_clips.erase(&"")
		print("   attack clips: ", attack_clips.keys())
		var variants := 2 if hero._anim.has_animation(&"general/Throw_2") else 1
		_check("attacks use %d clip(s)" % variants, attack_clips.size() == variants)

		for slot in Unit.HERO_ABILITY_SLOTS:
			var ability := hero.ability_at(slot)
			if ability == null or ability.is_passive():
				continue
			_quiet(heroes)
			hero.mana = hero.max_mana
			hero.ability_cooldowns[slot] = 0.0
			var seen := {}
			var spoke := {}
			match ability.action:
				AbilityDefinition.Action.ATTACK:
					hero.order_attack(dummy, Unit.Queue.NONE, slot)
				AbilityDefinition.Action.NO_TARGET:
					hero.order_cast(slot, UnitRegistry.NONE, hero.global_position, Unit.Queue.NONE)
				AbilityDefinition.Action.TARGET_UNIT:
					var target := hero.handle if ability.targets == AbilityDefinition.Targets.ALLIES else dummy
					hero.order_cast(slot, target, registry.position_of(target), Unit.Queue.NONE)
				_:
					hero.order_cast(slot, UnitRegistry.NONE, spot + Vector3(2, 0, -3), Unit.Queue.NONE)
			for step in 45:  # 1.5 s, tick by tick: the clips change on the game's clock
				await Simulation.current.ticked
				seen[hero._anim.current_animation] = true
				if hero._voice != null and hero._voice.playing:
					spoke[hero._voice.stream.resource_path.get_file() if not hero._voice.stream.resource_path.is_empty() else "randomized"] = true
				if step == 12 and slot == 0:
					await _shot("%s_cast" % hero.definition.display_name.to_lower())
			hero.order_stop()
			var expected: Array = EXPECTED.get(ability.id(), [&"", &""])
			print("   %s: clips %s, voice %s" % [ability.display_name, seen.keys(), spoke.keys()])
			_check("%s plays its clip" % ability.display_name, seen.has(expected[0]))
			if expected[1] != &"":
				_check("%s channels/strikes with its clip" % ability.display_name, seen.has(expected[1]))
			var has_line := hero._voice != null and hero._voice.voice.abilities.has(ability.id())
			if has_line:
				_check("%s is spoken" % ability.display_name, not spoke.is_empty())
			hero.mana = hero.max_mana
		registry.kill(dummy)
		await create_timer(0.3).timeout

	# Orders are acknowledged by the active hero
	_quiet(heroes)
	for hero in heroes:
		hero.teleport(Vector3(-4 + heroes.find(hero) * 3, 0, 24))
	camera.center_on(Vector3(0, 0, 22))
	commander.control_selection.assign(commander.heroes)
	commander.select_hero(0)
	await create_timer(0.2).timeout
	commander.give_order_position(Commander.Order.MOVE, Vector3(0, 0, 18), Unit.Queue.NONE)
	await create_timer(0.1).timeout
	var speaker := heroes[0]
	if speaker._voice != null and not speaker._voice.voice.move.is_empty():
		_check("the active hero answers a move order", speaker._voice.playing and speaker._voice.voice.move.has(speaker._voice.stream))
		var first := speaker._voice.stream
		commander.give_order_position(Commander.Order.MOVE, Vector3(0, 0, 16), Unit.Queue.NONE)
		await create_timer(0.1).timeout
		_check("a second order right after stays quiet (cooldown)", speaker._voice.stream == first)
	print("FAILURES: %d" % _failures)
	quit()


func _quiet(heroes: Array[Unit]) -> void:
	for hero in heroes:
		if hero._voice != null:
			hero._voice.stop()
			hero._voice._ready_at.clear()


func _spawn(kind: String, at: Vector3) -> int:
	var handle := registry.spawn_npc(load("res://data/units/%s.tres" % kind), 2, at, north)
	registry.hold_position(handle)  # stands still
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
