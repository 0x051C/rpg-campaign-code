class_name SelectionPanel
extends PanelContainer

## One button per selected unit (noh's multi-unit selection panel).
## Click: make it the active unit. Click twice: select only it. Shift+click: deselect.
## While a spell or an order is being aimed, a click aims it at that unit instead.

const SLOT_SIZE := Vector2(110.0, 48.0)
const ACTIVE_TINT := Color(1.0, 0.92, 0.5)

@export var commander: Commander

var _buttons: Array[Button] = []

@onready var _row: HBoxContainer = $Row


func _process(_delta: float) -> void:
	var units := commander.get_displayed_selection()
	visible = not units.is_empty()
	while _buttons.size() < units.size():
		_add_button()
	for i in _buttons.size():
		var button := _buttons[i]
		button.visible = i < units.size()
		if not button.visible:
			continue
		var handle := units[i]
		var definition := commander.registry.definition_of(handle)
		button.text = "%s\n%d / %d" % [definition.display_name, ceili(commander.registry.health_of(handle)), ceili(commander.registry.max_health_of(handle))]
		button.modulate = ACTIVE_TINT if handle == commander.active else Color.WHITE


func _add_button() -> void:
	var button := Button.new()
	button.custom_minimum_size = SLOT_SIZE
	button.focus_mode = Control.FOCUS_NONE
	button.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS  # one click, on press
	button.pressed.connect(_on_slot_pressed.bind(_buttons.size()))
	_row.add_child(button)
	_buttons.append(button)


func _on_slot_pressed(slot: int) -> void:
	var units := commander.get_displayed_selection()
	if slot < units.size() and commander.aim_at_unit(units[slot]):
		return
	if Input.is_action_pressed(&"rts_modifier_queue"):
		commander.deselect_unit(slot)
	else:
		commander.set_control_unit(slot)
