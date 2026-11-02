extends SceneTree
## Title screen, loading screen, Esc game menu with save slots. OUT=<prefix>

var _out := OS.get_environment("OUT")
var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var campaign := Campaign.current
	for header in campaign.list_saves():
		campaign.delete_save(header.slot)
	change_scene_to_file("res://scenes/ui/title.tscn")
	await create_timer(1.0).timeout
	await _shot("title")
	_check("no saves: no Continue", _button("Continue") == null and _button("New Game") != null)
	_button("New Game").pressed.emit()
	await process_frame
	await process_frame
	_check("loading screen up", campaign._loading.visible)
	await _shot("loading")
	for i in 150:  # real time: loading doesn't speed up with the game
		await create_timer(0.1, true, false, true).timeout
		if current_scene != null and Campaign.is_first_map(current_scene.scene_file_path):
			break
	await create_timer(2.0).timeout
	_check("the first map started", Campaign.is_first_map(current_scene.scene_file_path))
	var first_hero := (current_scene.get_node("UnitRegistry") as UnitRegistry).definition_of(
			(current_scene.get_node("Commander") as Commander).heroes[0]).display_name
	_check("loading screen gone", not campaign._loading.visible)
	(current_scene.get_node("RTSCamera") as RTSCamera).edge_scroll = false

	# Esc with nothing selected to cancel: the game menu, paused
	(current_scene.get_node("Commander") as Commander).info_selection.clear()
	_key(KEY_ESCAPE)
	await process_frame
	_check("Esc opened the game menu", campaign._menu.visible and paused)
	_button("Save game").pressed.emit()
	await process_frame
	await _shot("save_slots")
	var slot_button := _button_starting("Slot 2")
	_check("six empty slots to save into", slot_button != null and slot_button.text.ends_with("empty"))
	slot_button.pressed.emit()
	await process_frame
	_check("saved into slot 2, menu closed, unpaused", campaign.list_saves().any(func(h: Dictionary) -> bool: return h.slot == "slot2")
			and not campaign._menu.visible and not paused)
	_key(KEY_ESCAPE)
	await process_frame
	_button("Load game").pressed.emit()
	await process_frame
	await _shot("load_slots")
	_check("load list shows slot 2 with the party", _button_starting("Slot 2 — ") != null and _button_starting("Slot 2 — ").text.contains("%s 1" % first_hero))
	_button_starting("Slot 2 — ").pressed.emit()
	await campaign.loaded
	await create_timer(0.5).timeout
	_check("loaded slot 2", Campaign.is_first_map(current_scene.scene_file_path) and not paused)

	_key(KEY_ESCAPE)
	await process_frame
	_button("Quit to title").pressed.emit()
	await create_timer(1.5).timeout
	_check("back at the title, with Continue", current_scene.scene_file_path == campaign.TITLE_SCENE and _button("Continue") != null)
	await _shot("title_continue")
	print("FAILURES: %d" % _failures)
	await create_timer(float(OS.get_environment("LINGER") if OS.has_environment("LINGER") else "0")).timeout
	quit()


func _button(text: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button.text == text and button.is_visible_in_tree():
			return button
	return null


func _button_starting(text: String) -> Button:
	for node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button.text.begins_with(text) and button.is_visible_in_tree():
			return button
	return null


func _key(code: Key) -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.physical_keycode = code
		event.keycode = code
		event.pressed = pressed
		Input.parse_input_event(event)


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("%s_%s.png" % [_out, shot_name])
