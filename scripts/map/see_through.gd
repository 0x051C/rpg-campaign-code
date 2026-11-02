class_name SeeThrough
extends Node

## Lets the player see their units behind rocks, trees and buildings: every mesh on the
## "see_through" render layer (MapProps set it with their `see_through` flag; put any other
## mesh on layer 2 to opt in) gets a material that opens a soft round hole wherever it stands
## between the camera and a tracked unit. Tracked: the player's heroes and summons, plus the
## selected and hovered units. Add one to a game map, next to the Commander.

const LAYER := 2  ## render layer "see_through" (layer_names/3d_render/layer_2)
const MAX_UNITS := 32
const SHADER := preload("res://shaders/see_through.gdshader")

@export var commander: Commander
@export var registry: UnitRegistry
## Hole radius per meter of unit height, and its minimum.
@export var radius_per_height := 1.0
@export var min_radius := 1.3

var _image := Image.create(MAX_UNITS, 1, false, Image.FORMAT_RGBAF)
var _texture := ImageTexture.create_from_image(_image)
var _converted: Dictionary[Material, ShaderMaterial] = {}
var _blank := StandardMaterial3D.new()  ## stands in for surfaces without a material


func _ready() -> void:
	RenderingServer.global_shader_parameter_set(&"see_through_units", _texture)
	get_tree().node_added.connect(_on_node_added)
	for node in get_tree().root.find_children("*", "MeshInstance3D", true, false):
		convert_mesh(node as MeshInstance3D)
	for node in get_tree().root.find_children("*", "MultiMeshInstance3D", true, false):
		convert_multimesh(node as MultiMeshInstance3D)


func _exit_tree() -> void:
	RenderingServer.global_shader_parameter_set(&"see_through_count", 0)


func _process(_frame_time: float) -> void:
	var view := get_viewport().get_camera_3d()
	if view == null or registry == null:
		RenderingServer.global_shader_parameter_set(&"see_through_count", 0)
		return
	var count := 0
	for handle in _tracked():
		if count >= MAX_UNITS:
			break
		if not registry.is_alive(handle):
			continue
		var height := registry.height_of(handle)
		var center := Terrain.lift(registry.position_of(handle)) + Vector3.UP * height * 0.5
		var radius := maxf(min_radius, height * radius_per_height)
		_image.set_pixel(count, 0, Color(center.x, center.y, center.z, radius))
		count += 1
	_texture.update(_image.duplicate())  # its own: the render thread reads it later (shares the pixels until _image changes)
	RenderingServer.global_shader_parameter_set(&"see_through_count", count)
	RenderingServer.global_shader_parameter_set(&"see_through_camera", view.global_position)


## Gives a mesh on the see-through layer occluder materials (a copy of each StandardMaterial3D
## channel it uses). Other meshes are left alone.
func convert_mesh(mesh_instance: MeshInstance3D) -> void:
	if mesh_instance == null or not mesh_instance.get_layer_mask_value(LAYER) or mesh_instance.mesh == null:
		return
	var prop := _prop_of(mesh_instance)
	if prop != null:
		mesh_instance.set_instance_shader_parameter(&"hole_scale", prop.see_through_scale)
	if mesh_instance.material_override != null:
		mesh_instance.material_override = _convert(mesh_instance.material_override)
		return
	for surface in mesh_instance.mesh.get_surface_count():
		var material := mesh_instance.get_surface_override_material(surface)
		if material == null:
			material = mesh_instance.mesh.surface_get_material(surface)
		var converted := _convert(material)
		if converted != material:
			mesh_instance.set_surface_override_material(surface, converted)


## A batch of props on the see-through layer (MapPropBatch): converts the materials of its
## mesh in place; the batch gave it a mesh of its own.
func convert_multimesh(instance: MultiMeshInstance3D) -> void:
	if instance == null or not instance.get_layer_mask_value(LAYER) or instance.multimesh == null \
			or instance.multimesh.mesh == null:
		return
	var mesh := instance.multimesh.mesh
	for surface in mesh.get_surface_count():
		var material := mesh.surface_get_material(surface)
		var converted := _convert(material)
		if converted != material:
			mesh.surface_set_material(surface, converted)


static func _prop_of(node: Node) -> MapProp:
	while node != null:
		if node is MapProp:
			return node
		node = node.get_parent()
	return null


func _tracked() -> Array[int]:
	var handles: Array[int] = []
	for kind in [UnitRegistry.Kind.HERO, UnitRegistry.Kind.SUMMON]:  # heroes and summons
		var ids := registry.handles(kind)
		var teams := registry.int_column(kind, "team")
		for i in ids.size():
			if teams[i] == registry.player_team:
				handles.append(ids[i])
	if commander != null:
		for handle in commander.control_selection + commander.info_selection + [commander.hover]:
			if handle != UnitRegistry.NONE and not handles.has(handle):
				handles.append(handle)
	return handles


func _convert(material: Material) -> Material:
	if material == null:
		material = _blank
	var source := material as BaseMaterial3D
	if source == null:
		return material  # custom shaders are left as they are
	if _converted.has(source):
		return _converted[source]
	var occluder := ShaderMaterial.new()
	occluder.shader = SHADER
	occluder.set_shader_parameter(&"albedo_color", source.albedo_color)
	occluder.set_shader_parameter(&"albedo_texture", source.albedo_texture)
	occluder.set_shader_parameter(&"use_vertex_color", source.vertex_color_use_as_albedo)
	occluder.set_shader_parameter(&"roughness", source.roughness)
	occluder.set_shader_parameter(&"roughness_texture", source.roughness_texture)
	occluder.set_shader_parameter(&"metallic", source.metallic)
	occluder.set_shader_parameter(&"metallic_texture", source.metallic_texture)
	occluder.set_shader_parameter(&"use_normal_texture", source.normal_enabled and source.normal_texture != null)
	occluder.set_shader_parameter(&"normal_texture", source.normal_texture)
	occluder.set_shader_parameter(&"normal_scale", source.normal_scale)
	if source.emission_enabled:
		occluder.set_shader_parameter(&"emission", source.emission)
		occluder.set_shader_parameter(&"emission_energy", source.emission_energy_multiplier)
	occluder.set_shader_parameter(&"uv_scale", source.uv1_scale)
	occluder.set_shader_parameter(&"uv_offset", source.uv1_offset)
	_converted[source] = occluder
	return occluder


func _on_node_added(node: Node) -> void:
	if node is MeshInstance3D or node is MultiMeshInstance3D:
		_convert_later.call_deferred(node)  # after its owner set it up


func _convert_later(node: Object) -> void:
	if is_instance_valid(node):
		if node is MultiMeshInstance3D:
			convert_multimesh(node as MultiMeshInstance3D)
		else:
			convert_mesh(node as MeshInstance3D)
