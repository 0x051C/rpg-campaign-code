extends Control

## The title screen (after little_demo01's main menu): the tavern wallpaper under drifting
## mist, the game's name, and Continue (the newest save), New Game, Load Game and Quit.

const THEME := preload("res://assets/ui/menu_theme.tres")
const WALLPAPER := preload("res://assets/ui/images/wallpaper_4k_tavern.jpg")
const BOLD := preload("res://assets/ui/fonts/almendra/Almendra-Bold.ttf")

@export var game_title := "New Stranger"

var _buttons := VBoxContainer.new()
var _slots := SaveSlots.new()
var _slots_panel := PanelContainer.new()


func _ready() -> void:
	theme = THEME
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var wallpaper := TextureRect.new()
	wallpaper.texture = WALLPAPER
	wallpaper.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wallpaper.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	wallpaper.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(wallpaper)
	var mist := ColorRect.new()
	mist.color = Color(0, 0, 0, 0)
	mist.material = LoadingScreen._material(LoadingScreen.MIST, {&"mist_color": Vector4(0.025, 0.015, 0.075, 1.0),
			&"flowmap": LoadingScreen.FLOWMAP, &"radius": 2.56, &"smoothness": 2.755, &"speed": 1.0, &"noise_scale": 13.745,
			&"time_scale": 0.5})
	mist.set_anchors_preset(Control.PRESET_FULL_RECT)
	mist.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(mist)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 24)
	center.add_child(column)
	var title := Label.new()
	title.text = game_title
	var settings := LabelSettings.new()
	settings.font = BOLD
	settings.font_size = 72
	settings.outline_size = 6
	settings.outline_color = Color(0.13, 0.08, 0.3)
	title.label_settings = settings
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	_buttons.add_theme_constant_override(&"separation", 12)
	column.add_child(_buttons)
	var saves := Campaign.current.list_saves()
	if not saves.is_empty():
		_add_button("Continue", func() -> void: Campaign.current.load_game(saves[0].slot))
	_add_button("New Game", func() -> void: Campaign.current.new_game())
	var load_button := _add_button("Load Game", _show_slots)
	load_button.disabled = saves.is_empty()
	_add_button("Quit", func() -> void: get_tree().quit())
	_slots_panel.add_child(_slots)
	_slots_panel.visible = false
	column.add_child(_slots_panel)
	_slots.chosen.connect(func(slot: String) -> void: Campaign.current.load_game(slot))
	_slots.cancelled.connect(func() -> void:
		_slots_panel.visible = false
		_buttons.visible = true)


func _add_button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_size_override(&"font_size", 32)
	button.pressed.connect(action)
	_buttons.add_child(button)
	return button


func _show_slots() -> void:
	_buttons.visible = false
	_slots_panel.visible = true
	_slots.show_slots(SaveSlots.Mode.LOAD)
