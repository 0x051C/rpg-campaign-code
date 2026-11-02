@tool
extends EditorPlugin

## Godot only loads editor plugins from res://addons; the Tests dock itself lives next to the
## tests, in res://tests/framework/dock.gd (see res://CLAUDE.md).

var _dock: Control


func _enter_tree() -> void:
	_dock = load("res://tests/framework/dock.gd").new()
	_dock.name = "Tests"
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)


func _exit_tree() -> void:
	remove_control_from_docks(_dock)
	_dock.queue_free()
