class_name OrderMarker
extends MeshInstance3D

## Shrinking ground ring confirming a position order
## (noh: CLIENT_RESOURCE_MOVE_INDICATOR_EFFECT / ATTACK_INDICATOR_EFFECT).

const LIFETIME := 0.45

static var _mesh: TorusMesh


static func spawn(parent: Node, at: Vector3, color: Color) -> void:
	if _mesh == null:
		_mesh = TorusMesh.new()
		_mesh.inner_radius = 0.55
		_mesh.outer_radius = 0.7
	var marker := OrderMarker.new()
	marker.mesh = _mesh
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = UnitRegistry.GROUND_DECAL  # follows the terrain
	material.set_shader_parameter(&"color", color)
	marker.material_override = material
	parent.add_child(marker)
	marker.global_position = Vector3(at.x, 0.05, at.z)
	marker.scale = Vector3(1.6, 0.2, 1.6)

	var tween := marker.create_tween().set_parallel().set_ease(Tween.EASE_IN)
	tween.tween_property(marker, ^"scale", Vector3(0.3, 0.2, 0.3), LIFETIME)
	tween.tween_method(func(alpha: float) -> void: material.set_shader_parameter(&"color", Color(color, alpha)), color.a, 0.0, LIFETIME)
	tween.chain().tween_callback(marker.queue_free)
