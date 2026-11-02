extends SceneTree
## Can you walk there? Every wild map, in every generated layout, is opened and a path is asked from the hero start
## to each place the story or the loot needs (a step's trigger or person, the exits, chests, shrines): the end of
## the path must come within REACH of it. A place cut off by cliffs, trees or a wall fails (the cellar in the farmhouse
## was found by hand: this finds those before you do).

const REACH := 4.0  ## m; a person stands among props, so the path may end near them
const MAPS := ["broken_road", "hunt", "hollow", "debts"]

var _failures := 0
var _checked := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	for stem in MAPS:
		var layouts: Array[String] = ["res://scenes/maps/story/%s.tscn" % stem]
		var n := 1
		while ResourceLoader.exists("res://scenes/maps/story/%s_v%d.tscn" % [stem, n]):
			layouts.append("res://scenes/maps/story/%s_v%d.tscn" % [stem, n])
			n += 1
		for path in layouts:
			await _check_map(support, path)
	print("places checked: %d" % _checked)
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _check_map(support: Script, path: String) -> void:
	var map: Node3D = support.call(&"open_map", self, ["maren"], path)
	await create_timer(1.2).timeout
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var navigation := map.get_world_3d().navigation_map
	var start := (map.get_node("HeroStart") as Node3D).global_position
	var places := {}
	var story := map.get_node("Story")
	for node in story.find_children("*", "", true, false):
		if node is QuestStep:
			var step := node as QuestStep
			if step.trigger != null:
				places["trigger of '%s'" % step.objective.left(40)] = step.trigger.global_position
			if step.npc != null:
				places["%s ('%s')" % [step.npc.name, step.objective.left(40)]] = step.npc.global_position
		elif node is MapExit or node is Chest or node is Shrine:
			places[String(node.name)] = (node as Node3D).global_position
	# The control: a point far outside the map must NOT be reachable, or the navigation isn't ready and every pass means nothing
	var control := NavigationServer3D.map_get_path(navigation, start, start + Vector3(0, 0, 5000), true)
	var control_end := control[control.size() - 1] if control.size() > 0 else start
	if Vector2(control_end.x - start.x, control_end.z - start.z).length() > 4000.0:
		_failures += 1
		print("FAIL %s: the control point outside the map was 'reachable': the navigation isn't ready" % path.get_file())
	if NavigationServer3D.map_get_path(navigation, start, start + Vector3(3, 0, 3), true).size() == 0:
		_failures += 1
		print("FAIL %s: no path even three metres from the start: the navigation isn't ready" % path.get_file())
	for what: String in places:
		var at: Vector3 = places[what]
		var route := NavigationServer3D.map_get_path(navigation, start, at, true)
		_checked += 1
		var end := route[route.size() - 1] if route.size() > 0 else start
		var gap := Vector2(end.x - at.x, end.z - at.z).length()
		if route.size() == 0 or gap > REACH:
			_failures += 1
			print("FAIL %s: can't walk to %s (the path ends %.1f m short, at %s)" % [path.get_file(), what, gap, at])
	map.queue_free()
	await process_frame
	await process_frame


