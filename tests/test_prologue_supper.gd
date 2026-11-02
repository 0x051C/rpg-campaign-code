extends SceneTree
## The prologue's first supper, reached the way a player reaches it: the root cellar must be seen from the yard
## (not hidden in the farmhouse, where the walls blocked the party's sight), pointed at, right-clicked, and
## the supper must play and bless the party. (test_story walks the quest by signals and missed that the
## cellar couldn't be clicked at all.)

var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var map: Node3D = support.call(&"open_map", self, ["maren", "brook"], Campaign.FIRST_MAP)
	await create_timer(1.0).timeout
	for scene: StoryScene in map.find_children("*", "StoryScene", true, false):
		scene.skip()
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var commander: Commander = map.get_node("Commander")
	var camera: RTSCamera = map.find_child("RTSCamera", true, false)
	camera.edge_scroll = false
	var steps := (map.find_child("TheBrokenRoad", true, false) as Quest).get_children()
	for i in 4:
		if steps[i].is_active():
			steps[i].complete()
	for scene: StoryScene in map.find_children("*", "StoryScene", true, false):
		scene.skip()
	var cellar: NeutralSpawn = map.find_child("RootCellar", true, false)
	var at := registry.position_of(cellar.handle)
	_check("the supper step asks for the cellar, and says where", steps[4].is_active() and steps[4].tracker_text().contains("cellar"))
	_check("it can be talked to (a neutral with no lines is only followed)", registry.dialogue_of(cellar.handle) != null)
	for i in commander.heroes.size():
		registry.unit_of(commander.heroes[i]).teleport(at + Vector3(3 + i, 0, 3))
	camera.center_on(at)
	await create_timer(1.5).timeout
	_check("the party sees it from the yard", registry.player_sees(cellar.handle))
	var screen := camera.camera.unproject_position(Terrain.lift(at) + Vector3(0, 0.5, 0))
	var move := InputEventMouseMotion.new()
	move.position = screen
	move.global_position = screen
	Input.parse_input_event(move)
	await create_timer(0.5).timeout
	_check("pointing at it picks it", commander.hover == cellar.handle)
	var click := InputEventMouseButton.new()
	click.position = screen
	click.global_position = screen
	click.button_index = MOUSE_BUTTON_RIGHT
	click.pressed = true
	Input.parse_input_event(click)
	await create_timer(6.0).timeout
	var supper := map.find_child("SupperAtTheFarm", true, false) as StoryScene
	for i in 12:  # the scene plays by itself, faster at test speed; a nudge in case it waits
		if supper.playing:
			supper.skip()
		await create_timer(0.3).timeout
	_check("the right-click starts the supper scene", Campaign.current.is_opened(supper))
	_check("the step is done", not steps[4].is_active())
	var blessed := (map.get_node("Party") as PartyInventory).heroes().all(func(hero: Unit) -> bool:
		return hero.buffs().any(func(buff: Dictionary) -> bool: return buff.get("label", "") == "Honey cakes"))
	_check("the party is blessed by the honey cakes", blessed)
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
