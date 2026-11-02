class_name CorpseField
extends MultiMeshInstance3D

## The corpse system: every fallen creep leaves a pile of bones that slowly decays,
## sinking and darkening into the dirt until it is gone. Corpses are a structure of arrays
## kept in death order and drawn as one MultiMesh: one draw call for all of them, each tinted
## by its instance color. The bones are a prop model (`model`, by default the skulls of
## Kongor's pit) baked into a single mesh when the map loads. Heroes never end up here; their
## bodies stay where they fell. Like DotaCraft's corpses (vscripts/mechanics/corpses.lua) they
## remember who died, so spells can raise them. Corpses in the fog of war aren't drawn.


class Corpse:
	var position: Vector3
	var team: int
	var definition: UnitDefinition


const CAPACITY := 256
const BONE := Color(0.93, 0.9, 0.82)
const DIRT := Color(0.22, 0.17, 0.12)
const FLOATS_PER_INSTANCE := 16  ## 3x4 transform + color

@export var decay_time := 60.0
@export var final_scale := 0.5
@export var sink_depth := 0.35
## The corpse marker, baked into one mesh `model_size` meters across (its longer side) when the map loads.
@export var model: PackedScene = preload("res://assets/environment/hon/props/kongor/skulls/high_2.glb")
@export var model_size := 1.1

var corpse_positions := PackedVector3Array()
var corpse_yaws := PackedFloat32Array()
var corpse_ages := PackedFloat32Array()
var corpse_teams := PackedInt32Array()
var corpse_scales := PackedFloat32Array()
var corpse_definitions: Array[UnitDefinition] = []

var _buffer := PackedFloat32Array()


func _ready() -> void:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true  # the instance color tints the texture
	material.vertex_color_is_srgb = true
	material.roughness = 0.9
	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = _bake(model, model_size, material) if model != null else null
	material_override = material
	multimesh.instance_count = CAPACITY
	multimesh.visible_instance_count = 0
	_buffer.resize(CAPACITY * FLOATS_PER_INSTANCE)


func add(at: Vector3, yaw: float, team: int, definition: UnitDefinition, model_scale := 1.0) -> void:
	if corpse_ages.size() >= CAPACITY:
		_remove(0)
	corpse_positions.append(at)
	corpse_yaws.append(yaw)
	corpse_ages.append(0.0)
	corpse_teams.append(team)
	corpse_scales.append(model_scale)
	corpse_definitions.append(definition)


## Removes and returns up to `limit` corpses of `team` within `radius`, freshest first
## (DotaCraft Corpses:FindAlliedInRadius).
func take(center: Vector3, radius: float, team: int, limit: int) -> Array[Corpse]:
	var taken: Array[Corpse] = []
	for i in range(corpse_ages.size() - 1, -1, -1):
		if taken.size() >= limit:
			break
		var offset := corpse_positions[i] - center
		if corpse_teams[i] != team or Vector2(offset.x, offset.z).length() > radius:
			continue
		var corpse := Corpse.new()
		corpse.position = corpse_positions[i]
		corpse.team = corpse_teams[i]
		corpse.definition = corpse_definitions[i]
		taken.append(corpse)
		_remove(i)
	return taken


func count() -> int:
	return corpse_ages.size()


func save_state() -> Dictionary:
	return {
		"positions": corpse_positions.duplicate(),
		"yaws": corpse_yaws.duplicate(),
		"ages": corpse_ages.duplicate(),
		"teams": corpse_teams.duplicate(),
		"scales": corpse_scales.duplicate(),
		"definitions": SaveCodec.encode_resources(corpse_definitions),
	}


func load_state(data: Dictionary) -> void:
	corpse_positions = PackedVector3Array(data.positions)
	corpse_yaws = PackedFloat32Array(data.yaws)
	corpse_ages = PackedFloat32Array(data.ages)
	corpse_teams = PackedInt32Array(data.teams)
	corpse_scales = PackedFloat32Array(data.scales)
	SaveCodec.decode_resources_into(data.definitions, corpse_definitions)


func _process(delta: float) -> void:
	for i in corpse_ages.size():
		corpse_ages[i] += delta
	# Everyone decays at the same rate, so the oldest corpses are always in front
	while not corpse_ages.is_empty() and corpse_ages[0] >= decay_time:
		_remove(0)
	_upload()


func _remove(index: int) -> void:
	corpse_positions.remove_at(index)
	corpse_yaws.remove_at(index)
	corpse_ages.remove_at(index)
	corpse_teams.remove_at(index)
	corpse_scales.remove_at(index)
	corpse_definitions.remove_at(index)


func _upload() -> void:
	var total := 0
	for i in corpse_ages.size():
		if not FogOfWar.player_sees(corpse_positions[i]):
			continue
		var decay := clampf(corpse_ages[i] / decay_time, 0.0, 1.0)
		var size := lerpf(1.0, final_scale, decay) * corpse_scales[i]
		var orientation := Basis(Vector3.UP, corpse_yaws[i]).scaled(Vector3(size, size, size))
		var origin := Terrain.lift(corpse_positions[i]) + Vector3.DOWN * sink_depth * decay * corpse_scales[i]
		var color := BONE.lerp(DIRT, sqrt(decay))  # bones brown early, then slowly sink away
		var at := total * FLOATS_PER_INSTANCE
		total += 1
		_buffer[at + 0] = orientation.x.x
		_buffer[at + 1] = orientation.y.x
		_buffer[at + 2] = orientation.z.x
		_buffer[at + 3] = origin.x
		_buffer[at + 4] = orientation.x.y
		_buffer[at + 5] = orientation.y.y
		_buffer[at + 6] = orientation.z.y
		_buffer[at + 7] = origin.y
		_buffer[at + 8] = orientation.x.z
		_buffer[at + 9] = orientation.y.z
		_buffer[at + 10] = orientation.z.z
		_buffer[at + 11] = origin.z
		_buffer[at + 12] = color.r
		_buffer[at + 13] = color.g
		_buffer[at + 14] = color.b
		_buffer[at + 15] = color.a
	multimesh.buffer = _buffer
	multimesh.visible_instance_count = total


## Every mesh of `scene` merged into one surface, standing on y = 0 around the origin, `size`
## meters across its longer side; the first surface's color texture goes to `material`.
static func _bake(scene: PackedScene, size: float, material: StandardMaterial3D) -> ArrayMesh:
	var root := scene.instantiate()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var placement := Transform3D.IDENTITY  # not in the tree: no global transforms
		var at: Node = mesh_instance
		while at != root:
			placement = (at as Node3D).transform * placement
			at = at.get_parent()
		for surface in mesh_instance.mesh.get_surface_count():
			var source := mesh_instance.mesh.surface_get_arrays(surface)
			var offset := vertices.size()
			for vertex: Vector3 in source[Mesh.ARRAY_VERTEX]:
				vertices.append(placement * vertex)
			for normal: Vector3 in source[Mesh.ARRAY_NORMAL]:
				normals.append((placement.basis * normal).normalized())
			var surface_uvs: PackedVector2Array = source[Mesh.ARRAY_TEX_UV] if source[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
			surface_uvs.resize((source[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
			uvs.append_array(surface_uvs)
			for index: int in source[Mesh.ARRAY_INDEX]:
				indices.append(index + offset)
			var original := mesh_instance.get_active_material(surface) as BaseMaterial3D
			if material.albedo_texture == null and original != null:
				material.albedo_texture = original.albedo_texture
	root.free()
	if vertices.is_empty():
		return null
	var bounds := AABB(vertices[0], Vector3.ZERO)
	for vertex in vertices:
		bounds = bounds.expand(vertex)
	var fit := size / maxf(maxf(bounds.size.x, bounds.size.z), 0.001)
	var base := Vector3(bounds.get_center().x, bounds.position.y, bounds.get_center().z)
	for i in vertices.size():
		vertices[i] = (vertices[i] - base) * fit
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var baked := ArrayMesh.new()
	baked.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return baked
