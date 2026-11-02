class_name GameMenu
extends CanvasLayer

## The in-game menu on Esc (when there's nothing to cancel): resume, save into one of the six
## slots, load, back to the title screen, quit. It pauses the game while open, playing solo;
## online, saving is refused away from checkpoints (Campaign.save_refusal).

const THEME := preload("res://assets/ui/menu_theme.tres")

var _panel := PanelContainer.new()
var _buttons := VBoxContainer.new()
var _slots := SaveSlots.new()


func _ready() -> void:
	layer = 50
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.theme = THEME
	add_child(center)
	center.add_child(_panel)
	var column := VBoxContainer.new()
	_panel.add_child(column)
	column.add_child(_buttons)
	_buttons.add_theme_constant_override(&"separation", 6)
	var title := Label.new()
	title.text = "Paused"
	title.add_theme_font_size_override(&"font_size", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_buttons.add_child(title)
	_add_button("Resume", close)
	_add_button("Save game", func() -> void: _show_slots(SaveSlots.Mode.SAVE))
	_add_button("Load game", func() -> void: _show_slots(SaveSlots.Mode.LOAD))
	_add_button("Quit to title", func() -> void:
		close()
		Campaign.current.quit_to_title())
	_add_button("Quit game", func() -> void: get_tree().quit())
	column.add_child(_slots)
	_slots.visible = false
	_slots.chosen.connect(_on_slot_chosen)
	_slots.cancelled.connect(_show_buttons)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"rts_cancel"):
		if _slots.visible:
			_show_buttons()
		else:
			close()
		get_viewport().set_input_as_handled()


func open() -> void:
	visible = true
	_show_buttons()
	if not Campaign.current.online:
		get_tree().paused = true


func close() -> void:
	visible = false
	get_tree().paused = false


func _add_button(text: String, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(action)
	_buttons.add_child(button)


func _show_buttons() -> void:
	_buttons.visible = true
	_slots.visible = false


func _show_slots(mode: SaveSlots.Mode) -> void:
	_buttons.visible = false
	_slots.visible = true
	_slots.show_slots(mode, Campaign.current.save_refusal() if mode == SaveSlots.Mode.SAVE else "")


func _on_slot_chosen(slot: String) -> void:
	if _slots.mode == SaveSlots.Mode.SAVE:
		var error := Campaign.current.save_game(slot)
		close()
		Campaign.current.report(error, "Game saved")
	else:
		close()
		Campaign.current.load_game(slot)
