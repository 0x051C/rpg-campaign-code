@tool
extends EditorNode3DGizmoPlugin

## Outlines every MapProp's collision shape (orange; none for decorations), so you
## can see the collision sits where the model does, and makes props with generated
## visuals clickable as one piece (their meshes aren't part of the scene).

const COLLISION_COLOR := Color(1.0, 0.75, 0.25)


func _init() -> void:
	create_material("collision", COLLISION_COLOR)


func _get_gizmo_name() -> String:
	return "MapProp"


func _has_gizmo(node: Node3D) -> bool:
	return node is MapProp


func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var prop := gizmo.get_node_3d() as MapProp
	var faces := prop.get_selection_faces()
	if not faces.is_empty():
		var triangles := TriangleMesh.new()
		if triangles.create_from_faces(faces):
			gizmo.add_collision_triangles(triangles)
	var lines := prop.get_collision_lines()
	if not lines.is_empty():
		gizmo.add_lines(lines, get_material("collision", gizmo))
