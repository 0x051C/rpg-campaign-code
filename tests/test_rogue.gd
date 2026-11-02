extends SceneTree
## The Rogue on the main map (waves off, Rogue first in the party). OUT=<prefix> for a screenshot.

var _out := OS.get_environment("OUT")
var _failures := 0
var registry: UnitRegistry
var north: CreepSpawner


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var campaign := Campaign.current
	var scene: Node3D = load("res://scenes/main.tscn").instantiate()
	var party: Array[UnitDefinition] = [load("res://data/units/rogue_hero.tres"), load("res://data/units/knight.tres"), load("res://data/units/mage.tres")]
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
	var rogue := registry.unit_of(commander.heroes[0])
	for i in [1, 2]:  # the others wait far away
		registry.unit_of(commander.heroes[i]).teleport(Vector3(-40 + i * 3, 0, 60))

	# Level 1
	_near("health", registry.max_health_of(rogue.handle), 380.0)
	_near("max mana", rogue.max_mana, 120.0)
	_near("starts with no combo", rogue.mana, 0.0)
	_near("combo drains", rogue.stats.value(Stats.Stat.MANA_REGEN), -2.0)
	_near("attack damage", rogue.attack_damage(), 24.0)
	_near("parry %", rogue.stats.effective(Stats.Stat.PARRY), 100.0 * 12.2 / 112.2, 0.01)
	_near("backstab %", rogue.stats.value(Stats.Stat.BACKSTAB_DAMAGE), 36.0)
	_near("combo power %", rogue.stats.value(Stats.Stat.COMBO_POWER), 14.0)
	_check("8 passives", rogue.definition.all_passives().size() == 8)

	# Hits build combo
	rogue.teleport(Vector3(0, 0, 10))
	var minion := _spawn("skeleton_minion", Vector3(0, 0, 8.6))
	rogue.order_attack(minion, Unit.Queue.NONE)
	await create_timer(3.0).timeout
	print("   combo after 3 s of hitting: %.1f" % rogue.mana)
	_check("hitting builds combo", rogue.mana > 10.0)
	rogue.order_stop()

	# Backstab: behind a creep facing away
	registry.place(minion, registry.position_of(minion), 0.0)  # facing +Z
	rogue.teleport(registry.position_of(minion) + Vector3(0, 0, -1.2))
	_check("standing behind counts as backstab", rogue.is_behind(minion))
	rogue.teleport(registry.position_of(minion) + Vector3(0, 0, 1.2))
	_check("standing in front doesn't", not rogue.is_behind(minion))

	# Riposte: parry most attacks, each parry gives combo
	rogue.skill_points = 10
	rogue.learn(2)
	registry.set_invulnerable(minion, false)
	commander.select_hero(0)
	commander.activate_ability(2)
	await create_timer(0.3).timeout
	_near("Riposte parry %", registry.parry_of(rogue.handle), 100.0 * 312.2 / 412.2, 0.1)
	var health_before := registry.health_of(rogue.handle)
	var mana_before := rogue.mana
	var parried := [0]
	registry.attack_parried.connect(func(_v: int, _s: int) -> void: parried[0] += 1)
	# Evasion rolls before parry, so about 60% of hits are parried: 30 of them make that clear
	# (10 fell short of half now and then)
	for i in 30:
		registry.apply_damage(rogue.handle, 20.0, minion)
	print("   parried %d of 30 attacks, combo %.1f -> %.1f" % [parried[0], mana_before, rogue.mana])
	_check("most attacks parried", parried[0] >= 12)
	_check("parries gave combo", rogue.mana > mana_before)
	_check("parried attacks did no damage", registry.health_of(rogue.handle) >= health_before - 20.0 * (30 - parried[0]))

	# Vanish
	rogue.learn(0)
	rogue.mana = 50.0
	var enemy := _spawn("skeleton_minion", Vector3(4, 0, 12))
	await create_timer(0.6).timeout
	_check("enemy sees the rogue before", registry.can_see(2, rogue.handle))
	commander.activate_ability(0)
	await create_timer(0.2).timeout
	_check("vanished: stealthed", rogue.is_stealthed())
	_check("enemies can't see the rogue", not registry.can_see(2, rogue.handle))
	_check("the player still sees their rogue", registry.player_sees(rogue.handle))
	await _shot("stealth")
	rogue.order_attack(enemy, Unit.Queue.NONE)
	await create_timer(2.0).timeout
	_check("attacking ended stealth", not rogue.is_stealthed())
	_check("ambush buff: faster attacks", rogue.stats.value(Stats.Stat.ATTACK_SPEED) > 22.0 + 30.0)
	rogue.order_stop()

	# Eviscerate spends everything (cast directly: no auto-attacks in between)
	rogue.learn(1)
	var spell := SpellCast.new()
	spell.ability = rogue.ability_at(1)
	spell.level = 1
	spell.caster = rogue
	spell.registry = registry
	spell.target = enemy
	spell.mana_spent = 25.0
	rogue.mana = 55.0  # 80 in all
	registry.set_invulnerable(enemy, false)
	var enemy_health := registry.health_of(enemy)
	spell.ability.cast(spell)
	var expected := (30.0 + 1.0 * 80.0) * (1.0 + rogue.stats.value(Stats.Stat.SPELL_DAMAGE) / 100.0)
	_near("Eviscerate: (30 + 80 mana) x spell damage", enemy_health - registry.health_of(enemy), minf(expected, enemy_health), 0.5)
	_near("all combo spent", rogue.mana, 0.0, 0.01)

	# Swift Slashes
	rogue.add_experience(3000.0)
	rogue.skill_points = 10
	rogue.learn(3)
	rogue.mana = 120.0
	var targets: Array[int] = []
	for i in 3:
		var creep := _spawn("skeleton_warrior", Vector3(-3 + i * 2.0, 0, 16))
		registry.set_invulnerable(creep, false)
		targets.append(creep)
	await create_timer(0.5).timeout
	var total_before := 0.0
	for creep in targets:
		total_before += registry.health_of(creep)
	commander.activate_ability(3)
	commander._cast(targets[1], registry.position_of(targets[1]))
	await create_timer(3.0).timeout
	var total_after := 0.0
	for creep in targets:
		total_after += registry.health_of(creep) if registry.is_alive(creep) else 0.0
	print("   Swift Slashes dealt %.0f" % (total_before - total_after))
	_check("Swift Slashes struck", total_before - total_after > 50.0)

	# Save and load while stealthed with a buff
	rogue.order_stop()
	rogue.teleport(Vector3(30, 0, 30))  # away from every enemy, so nothing ends the stealth
	await create_timer(0.3).timeout
	rogue.add_buff(&"riposte", "Riposte", "Rp", Color.WHITE, "test", 30.0, {Stats.Stat.PARRY: 300.0})
	rogue.vanish(30.0, 60.0, 4.0)
	await create_timer(0.2).timeout
	_check("save", campaign.save_game("rogue").is_empty())
	campaign.load_game("rogue")
	await campaign.loaded
	await create_timer(0.3).timeout
	var map := current_scene
	registry = map.get_node("UnitRegistry")
	var loaded_rogue := registry.unit_of((map.get_node("Commander") as Commander).heroes[0])
	_check("loaded rogue still stealthed", loaded_rogue.is_stealthed() and not registry.can_see(2, loaded_rogue.handle))
	_check("loaded rogue keeps its Riposte buff", registry.parry_of(loaded_rogue.handle) > 50.0)

	# Screenshot: the rogue's bar with passives and buffs, hovering Combo
	(map.get_node("Commander") as Commander).select_hero(0)
	(map.get_node("RTSCamera") as RTSCamera).center_on(loaded_rogue.global_position)
	var panel: SpellPanel = map.get_node("HUD/SpellPanel")
	await create_timer(0.3).timeout
	_hover(panel._info_icon.get_global_rect().get_center())
	await create_timer(0.3).timeout
	await _shot("bar")
	print("FAILURES: %d" % _failures)
	quit()


func _spawn(kind: String, at: Vector3) -> int:
	var handle := registry.spawn_npc(load("res://data/units/%s.tres" % kind), 2, at, north)
	registry.hold_position(handle)  # stands still
	return handle


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
