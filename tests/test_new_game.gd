extends SceneTree
## New Game from the title screen starts the prologue, its tutorial there but quiet.

func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	change_scene_to_file("res://scenes/ui/title.tscn")
	await create_timer(1.0).timeout
	var new_game: Button = null
	for node in root.find_children("*", "Button", true, false):
		if (node as Button).text == "New Game":
			new_game = node
	new_game.pressed.emit()
	for i in 150:
		await create_timer(0.1, true, false, true).timeout  # real time: loading doesn't speed up with the game
		if current_scene != null and Campaign.is_first_map(current_scene.scene_file_path) and current_scene.has_node("Tutorial"):
			break
	await create_timer(1.5).timeout
	var map := current_scene
	var tutorial := map.get_node_or_null("Tutorial") as Tutorial
	var commander: Commander = map.get_node("Commander")
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var ok := Campaign.is_first_map(map.scene_file_path) and tutorial != null and tutorial.current == null \
			and commander.heroes.size() == 1
	print("map %s, heroes %s, hint %s" % [map.scene_file_path, commander.heroes.map(func(h: int) -> String: return registry.definition_of(h).display_name),
			tutorial.current.name if tutorial != null and tutorial.current != null else "none"])
	print("%s New Game starts the prologue, the tutorial quietly waiting" % ("ok  " if ok else "FAIL"))
	print("FAILURES: %d" % (0 if ok else 1))
	quit()
