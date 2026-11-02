class_name CliffBatch
extends MapPropBatch

## A MapPropBatch for the cliff pieces of imported HoN maps (tools/noh/noh_map.gd): before
## batching them it draws them with shaders/cliff.gdshader, which leaves out their upward faces.
## Those lie flush with the high ground, where the terrain's own texture should show, as HoN's
## cliff shader blends them into the terrain.

const SHADER := preload("res://shaders/cliff.gdshader")


func _ready() -> void:
	var converted := {}  # one cliff material per original material, so the batch still groups them
	for node in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		for surface in mesh_instance.mesh.get_surface_count():
			var original := mesh_instance.get_active_material(surface)
			if not converted.has(original):
				converted[original] = _cliff_material(original)
			mesh_instance.set_surface_override_material(surface, converted[original])
	super._ready()


static func _cliff_material(original: Material) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SHADER
	var standard := original as BaseMaterial3D
	if standard != null:
		material.set_shader_parameter(&"albedo_texture", standard.albedo_texture)
		material.set_shader_parameter(&"albedo_color", standard.albedo_color)
		material.set_shader_parameter(&"roughness", standard.roughness)
	return material
