class_name EconomyWindow
extends CanvasLayer

## A window over the paused game, in the menus' style: the inn's rest (RestWindow), a trade
## (TradeWindow). Esc closes it. Subclasses fill `content` in build() and call refresh().

const THEME := preload("res://assets/ui/menu_theme.tres")
const GOLD := Color(1.0, 0.85, 0.35)
const DIM := Color(0.75, 0.75, 0.75)

signal closed

var content := VBoxContainer.new()
var _was_paused := false


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.theme = THEME
	add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	content.add_theme_constant_override(&"separation", 8)
	content.custom_minimum_size = Vector2(560, 0)
	panel.add_child(content)
	_was_paused = get_tree().paused
	get_tree().paused = true
	build()
	refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"rts_cancel") or event.is_action_pressed(&"ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func close() -> void:
	get_tree().paused = _was_paused
	closed.emit()
	queue_free()


func build() -> void:
	pass


func refresh() -> void:
	pass


func label(text: String, size := 18, color := Color.WHITE) -> Label:
	var line := Label.new()
	line.text = text
	line.add_theme_font_size_override(&"font_size", size)
	line.add_theme_color_override(&"font_color", color)
	line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return line


func button(text: String, pressed: Callable) -> Button:
	var choice := Button.new()
	choice.text = text
	choice.add_theme_font_size_override(&"font_size", 17)
	choice.pressed.connect(pressed)
	return choice


static func party() -> PartyInventory:
	return (Engine.get_main_loop() as SceneTree).get_first_node_in_group(PartyInventory.GROUP) as PartyInventory


## What an item does, in one line: its bonuses, its ability.
static func describe(item: ItemDefinition) -> String:
	var parts: PackedStringArray = []
	for stat: Stats.Stat in item.bonuses:
		var amount := item.bonuses[stat]
		parts.append("%s%s %s" % ["+" if amount >= 0.0 else "", AbilityDefinition.format_number(amount), Stats.NAMES.get(stat, str(stat)).to_lower()])
	if item.ability != null:
		parts.append(item.ability.display_name)
	return ", ".join(parts)
