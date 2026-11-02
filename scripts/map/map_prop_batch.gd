class_name MapPropBatch
extends Node3D

## Draws many props (a forest) as MultiMesh instances instead of a node per mesh. Put
## MapProps under it as usual: in the editor they stay separate nodes, placed, settled and
## edited one by one. When the game starts their meshes move into MultiMeshInstance3Ds, one
## per mesh, look and CHUNK-meter square (so chunks off screen are culled). Each prop keeps
## its node and its collision footprint (footprint, footprint_scale), so the navigation
## mesh, the fog of war and see-through holes work exactly as for single props.
##
## Plain models among its children (no MapProp inside: decorations with nothing to collide
## with, like an imported map's cliff pieces) join the batch too, and their nodes go: just data.

const CHUNK := 32.0

var _groups := {}  # look + chunk -> {mesh, shadow, see_through, hole_scale, transforms}
var _meshes := {}  # look -> the batch's own copy of the mesh with the prop's materials


func _ready() -> void:
	var into_batch := global_transform.affine_inverse()
	for node in find_children("*", "Node3D", true, false):
		var prop := node as MapProp
		if prop != null:
			for part in prop.take_visuals():
				_add(part, into_batch, prop.see_through, prop.see_through_scale)
	for child in get_children():
		if child is Node3D and not _has_prop(child):
			for part in _plain_visuals(child as Node3D):
				_add(part, into_batch, false, 1.0)
			remove_child(child)
			child.queue_free()
	for key: String in _groups:
		add_child(_instance(_groups[key]))
	_groups.clear()
	_meshes.clear()


func _add(part: Dictionary, into_batch: Transform3D, see_through: bool, hole_scale: float) -> void:
	var where: Vector3 = part.transform.origin
	var chunk := Vector2i(floori(where.x / CHUNK), floori(where.z / CHUNK))
	var look := "%d|%s|%d|%d|%.2f" % [(part.mesh as Mesh).get_instance_id(),
			",".join((part.materials as Array).map(func(m: Material) -> String: return str(m.get_instance_id()) if m else "-")),
			part.shadow, int(see_through), hole_scale]
	var key := "%s|%d,%d" % [look, chunk.x, chunk.y]
	if not _groups.has(key):
		if not _meshes.has(look):
			_meshes[look] = _mesh_copy(part.mesh, part.materials)
		_groups[key] = {"mesh": _meshes[look], "shadow": part.shadow, "see_through": see_through,
				"hole_scale": hole_scale, "transforms": []}
	_groups[key].transforms.append(into_batch * part.transform)


static func _has_prop(node: Node) -> bool:
	if node is MapProp:
		return true
	for child in node.get_children():
		if _has_prop(child):
			return true
	return false


## A plain model's meshes as MapProp.take_visuals() hands them over: {mesh, materials, transform, shadow}.
static func _plain_visuals(model: Node3D) -> Array[Dictionary]:
	var parts: Array[Dictionary] = []
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null or not mesh_instance.visible:
			continue
		var materials: Array[Material] = []
		for surface in mesh_instance.mesh.get_surface_count():
			materials.append(mesh_instance.get_active_material(surface))
		parts.append({"mesh": mesh_instance.mesh, "materials": materials,
				"transform": mesh_instance.global_transform, "shadow": mesh_instance.cast_shadow})
	return parts


## A copy of `mesh` with the surface materials the prop drew it with. Every batch has its
## own, since SeeThrough converts the materials of the meshes on its layer in place.
static func _mesh_copy(mesh: Mesh, materials: Array) -> Mesh:
	var copy: Mesh = mesh.duplicate()
	for surface in mini(copy.get_surface_count(), materials.size()):
		copy.surface_set_material(surface, materials[surface])
	return copy


static func _instance(group: Dictionary) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = group.mesh
	var transforms: Array = group.transforms
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	instance.cast_shadow = group.shadow
	instance.set_layer_mask_value(SeeThrough.LAYER, group.see_through)
	if group.see_through:
		instance.set_instance_shader_parameter(&"hole_scale", group.hole_scale)
	return instance
