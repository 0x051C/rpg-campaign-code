@tool
class_name MapObstacle
extends MapProp

## A MapProp made of one primitive, for blocking out a map before real models
## exist: a box (walls) or a tapered cylinder (rocks), built from `shape` and
## `size` with a matching collision shape. Prefabs: scenes/props/obstacles.

enum Shape { BOX, CYLINDER }

const STONE := preload("res://data/materials/stone.tres")

@export var shape := Shape.BOX:
	set(value):
		shape = value
		refresh()
## Box: width, height and depth. Cylinder: x is the base diameter, y the height.
@export var size := Vector3(2.0, 2.0, 2.0):
	set(value):
		size = value.max(Vector3.ONE * 0.1)
		refresh()
## Cylinder only: the top radius as a fraction of the base, for tapered rocks.
@export_range(0.0, 1.0) var taper := 1.0:
	set(value):
		taper = value
		refresh()
## Cylinder only.
@export_range(3, 64) var sides := 16:
	set(value):
		sides = value
		refresh()
@export var material: Material = STONE:
	set(value):
		material = value
		refresh()

var _mesh_instance: MeshInstance3D


## The collision is the primitive itself, so the footprint options don't apply.
func _validate_property(property: Dictionary) -> void:
	if property.name in [&"footprint", &"footprint_scale"]:
		property.usage = PROPERTY_USAGE_STORAGE


func get_selection_faces() -> PackedVector3Array:
	var faces := PackedVector3Array()
	if _mesh_instance != null and _mesh_instance.mesh != null:
		for face in _mesh_instance.mesh.get_faces():
			faces.append(face + _mesh_instance.position)
	return faces


func _build_visual() -> void:
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()  # generated, not owned, never saved
		add_child(_mesh_instance)
	var mesh: PrimitiveMesh
	if shape == Shape.BOX:
		var box := BoxMesh.new()
		box.size = size
		mesh = box
	else:
		var cylinder := CylinderMesh.new()
		cylinder.bottom_radius = size.x * 0.5
		cylinder.top_radius = size.x * 0.5 * taper
		cylinder.height = size.y
		cylinder.radial_segments = sides
		cylinder.rings = 1
		mesh = cylinder
	mesh.material = material
	_mesh_instance.mesh = mesh
	_mesh_instance.position = Vector3.UP * size.y * 0.5


func _fit_collision(scaling: Vector3) -> void:
	var scaled := size * scaling
	if shape == Shape.BOX:
		var box := BoxShape3D.new()
		box.size = scaled
		_collision.shape = box
	else:
		# A cylinder can't stretch sideways, so a squashed rock gets the average width
		var cylinder := CylinderShape3D.new()
		cylinder.radius = (scaled.x + size.x * scaling.z) * 0.25
		cylinder.height = scaled.y
		_collision.shape = cylinder
	_collision.position = Vector3.UP * scaled.y * 0.5
