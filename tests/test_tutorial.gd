extends SceneTree
## The quiet tutorial on the prologue: hints only when the player seems stuck, gone as soon as
## they do it, never for what they found out alone; what they know survives a save; a recruited
## villager joins as a hero and brings the two-hero hint; killing the ledger ends the hints.
## OUT=<prefix> for screenshots.

var _out := OS.get_environment("OUT")
var _failures := 0
var map: Node3D
var registry: UnitRegistry
var commander: Commander
var tutorial: Tutorial
var camera: RTSCamera


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")

	# A player who acts at once never sees the hint for it
	await _open()
	var rogue := registry.unit_of(commander.heroes[0])
	commander.give_order_position(Commander.Order.MOVE, rogue.global_position + Vector3(2, 0, -2), Unit.Queue.NONE)
	await create_timer(10.0).timeout
	_check("moving right away: the move hint never shows", tutorial.knows(&"move")
			and _shown("Move") == 0 and (tutorial.current == null or tutorial.current.name != "Move"))

	# A player who stands still gets it after a few seconds, and it goes when they move
	await _open()
	rogue = registry.unit_of(commander.heroes[0])
	await create_timer(3.0).timeout
	_check("no hint in the first seconds", tutorial.current == null)
	await create_timer(4.0).timeout
	_check("standing still: the move hint shows", tutorial.current != null and tutorial.current.name == "Move")
	await _shot("move_hint")
	camera.center_on(rogue.global_position)
	await create_timer(0.3).timeout
	commander.give_order_position(Commander.Order.MOVE, rogue.global_position + Vector3(2, 0, -2), Unit.Queue.NONE)
	await process_frame
	_check("moving: it goes away", tutorial.current == null)
	# The Rogue has an unspent skill point: a while later, a hint about learning
	await create_timer(14.0).timeout
	_check("an unspent skill point: the learn hint", tutorial.current != null and tutorial.current.name == "Learn")
	commander.select_hero(0)
	commander.learn_ability(0)
	await process_frame
	_check("learning a spell: it goes away", tutorial.current == null and tutorial.knows(&"learn"))

	# What the player knows survives a save
	_check("save", Campaign.current.save_game("tutorial").is_empty())
	Campaign.current.load_game("tutorial")
	await Campaign.current.loaded
	await create_timer(0.6).timeout
	_bind()
	_check("after loading it still knows moving and learning", tutorial.knows(&"move") and tutorial.knows(&"learn"))

	# A villager who joins: the two-hero hint
	rogue = registry.unit_of(commander.heroes[0])
	var villager := NeutralSpawn.new()
	villager.name = "Recruit"
	villager.definition = load("res://data/units/barbarian.tres")
	villager.recruit_as = load("res://data/units/knight.tres")
	villager.recruit_after_talk = true
	var words := Dialogue.new()
	words.lines = PackedStringArray(["I'll come with you."])
	words.characters_per_second = 200.0
	words.line_pause = 0.3
	villager.dialogue = words
	villager.position = rogue.global_position + Vector3(2.5, 0, 0)
	map.add_child(villager)
	villager.owner = map
	await create_timer(0.3).timeout
	rogue.level = 3
	camera.center_on(rogue.global_position)
	commander.give_order_unit(Commander.Order.TALK, villager.handle, Unit.Queue.NONE)
	var row := villager.handle
	for i in 60:
		await create_timer(0.1).timeout
		if commander.heroes.size() == 2:
			break
	var knight := registry.unit_of(commander.heroes[1]) if commander.heroes.size() == 2 else null
	_check("after hearing it out, the villager joins as a Knight", knight != null and knight.definition.display_name == "Knight")
	_check("at the party's level, with skill points", knight != null and knight.level == 3 and knight.skill_points == 3)
	_check("the villager is gone from the map for good", not registry.is_alive(row) and Campaign.current.is_opened(villager))
	var two_heroes := false
	for i in 40:
		await create_timer(0.5).timeout
		if tutorial.current != null and tutorial.current.name == "TwoHeroes":
			two_heroes = true
			break
	_check("two heroes: a hint about picking them", two_heroes)
	await _shot("two_heroes_hint")
	await _key(KEY_F2)
	_check("F2: it goes away", tutorial.current == null or tutorial.current.name != "TwoHeroes")

	# Killing the ledger: no more hints
	await _open()
	var ledger: NeutralSpawn = map.get_node("WellCheckpoint/ledger")
	var ended := [false]
	tutorial.ended.connect(func() -> void: ended[0] = true)
	registry.apply_damage(ledger.handle, 9999.0, commander.heroes[0], false)
	await create_timer(12.0).timeout
	_check("killing the ledger ends the hints", ended[0] and tutorial.is_over() and tutorial.current == null)
	print("FAILURES: %d" % _failures)
	quit()


func _open() -> void:
	Campaign.current.flags = {}
	change_scene_to_file("res://scenes/maps/prologue.tscn")
	await create_timer(1.5).timeout
	_bind()


func _bind() -> void:
	map = current_scene
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	tutorial = map.get_node("Tutorial")
	camera = map.get_node("RTSCamera")
	camera.edge_scroll = false


func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame


func _shown(lesson: String) -> int:
	return Campaign.current.flags.get("tutorial", {}).get("shown", {}).get(lesson, 0)


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _shot(shot_name: String) -> void:
	if _out.is_empty():
		return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("%s_%s.png" % [_out, shot_name])
