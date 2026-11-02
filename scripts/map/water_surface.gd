@tool
class_name WaterSurface
extends Node3D

## Draws every mesh under it with one material: water surfaces whose own shaders don't carry
## over, like the rivers, wells and tar pits of maps imported from HoN (tools/noh/noh_map.gd).
## Units walk under it as if it weren't there; the terrain decides where they can go.

@export var material: Material:
	set(value):
		material = value
		if is_inside_tree():
			_apply()


func _ready() -> void:
	_apply()


func _apply() -> void:
	for node in find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).material_override = material
