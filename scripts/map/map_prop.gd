@tool
class_name MapProp
extends Node3D

## Anything placed on a map. Put the visuals (a model, a few models, meshes) under it
## and save it as a prefab scene in scenes/props, or just drop a raw model into a
## map: the Map Editor plugin turns it into a MapProp. Either way the prop moves as
## one piece and stays on the ground.
##
## Props that block movement build a collision body from their meshes and join the
## navigation geometry group, so the navigation mesh goes around them wherever they
## sit in the scene tree. Decorations (blocks_movement off) are only visuals.
##
## On a Terrain the prop stands on the drawn ground, but its collision stays on the
## gameplay plane (y = GROUND_HEIGHT), where units move and the navigation mesh is baked.
##
## Props that block movement also block sight (FogOfWar) for units whose eyes are below
## their top: walls and big rocks hide what is behind them, crates and fences don't.

enum Footprint { CONVEX_HULL, BOX, CYLINDER }

const NAVIGATION_GROUP := &"navigation_geometry"  ## the map's NavigationMesh bakes this group
const GROUP := &"map_props"  ## every prop; the Terrain re-settles them when it is sculpted
const GROUND_HEIGHT := 0.0  ## the gameplay plane; the terrain is drawn above it
const LAYER_WORLD := 1

## Units walk around it; off for decorations they walk through.
@export var blocks_movement := true:
	set(value):
		blocks_movement = value
		refresh()
## How the collision wraps the meshes.
@export var footprint := Footprint.CONVEX_HULL:
	set(value):
		footprint = value
		refresh()
## Shrinks the collision sideways, e.g. down to a tree's trunk.
@export_range(0.05, 1.0, 0.05) var footprint_scale := 1.0:
	set(value):
		footprint_scale = value
		refresh()
## In the editor, stand back upright on the ground after every move or turn.
@export var keep_on_ground := true
## Hides what is behind it in the fog of war; only for props that block movement.
@export var blocks_vision := true
## In game, opens a see-through hole where it hides the player's units (SeeThrough).
@export var see_through := true
## How wide that hole opens; larger for roofs, so the room under them shows.
@export_range(0.5, 5.0, 0.1) var see_through_scale := 1.0

var _body: StaticBody3D
var _collision: CollisionShape3D
var _built_scale := Vector3.ONE
var _batched_top := NAN  ## set once a MapPropBatch took its meshes: get_top() from then on


func _ready() -> void:
	if keep_on_ground and not Engine.is_editor_hint():
		_settle()  # the terrain may have been reshaped since the map was saved
	refresh()


func _enter_tree() -> void:
	add_to_group(GROUP)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and Engine.is_editor_hint():
		if keep_on_ground:
			_settle()
		if not basis.get_scale().abs().is_equal_approx(_built_scale):
			_build_collision()
		else:
			_place_body()


## Stands the prop back on the ground, e.g. after the terrain under it was reshaped.
func settle() -> void:
	if keep_on_ground:
		_settle()


## Rebuilds the generated parts. The Map Editor calls it after turning a dropped
## model into a prop, since that node was ready before it had this script.
func refresh() -> void:
	if not is_inside_tree() or not is_nan(_batched_top):
		return  # still loading (_ready builds it), or its meshes live in a MapPropBatch now
	if Engine.is_editor_hint():
		set_notify_transform(true)
		# Clicking any model inside selects the prop, so its parts never drift apart
		set_meta(&"_edit_group_", true)
	_build_visual()
	_build_collision()
	if not Engine.is_editor_hint():
		for mesh in find_children("*", "MeshInstance3D", true, false):
			(mesh as MeshInstance3D).set_layer_mask_value(SeeThrough.LAYER, see_through)
	update_gizmos()


## Faces the editor can click to select the prop, in its own space. Imported models
## are clickable already; generated visuals must list their faces here.
func get_selection_faces() -> PackedVector3Array:
	return PackedVector3Array()


## The collision shape's outline as line segment pairs, in the prop's own space.
func get_collision_lines() -> PackedVector3Array:
	var lines := PackedVector3Array()
	if _collision == null or _collision.shape == null:
		return lines
	var to_prop := _body.transform * _collision.transform
	var debug_mesh := _collision.shape.get_debug_mesh()
	for surface in debug_mesh.get_surface_count():
		for point: Vector3 in debug_mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]:
			lines.append(to_prop * point)
	return lines


## The collision outline seen from above, in world XZ; empty when it blocks no movement.
func get_footprint() -> PackedVector2Array:
	var points := PackedVector2Array()
	if _collision == null or _collision.shape == null or not _collision.is_inside_tree():
		return points
	var placement := _collision.global_transform
	var shape := _collision.shape
	var corners := PackedVector3Array()
	if shape is BoxShape3D:
		var half := (shape as BoxShape3D).size * 0.5
		corners = PackedVector3Array([Vector3(-half.x, 0.0, -half.z), Vector3(half.x, 0.0, -half.z),
				Vector3(half.x, 0.0, half.z), Vector3(-half.x, 0.0, half.z)])
	elif shape is CylinderShape3D:
		var radius := (shape as CylinderShape3D).radius
		for i in 16:
			var angle := TAU * i / 16.0
			corners.append(Vector3(cos(angle) * radius, 0.0, sin(angle) * radius))
	elif shape is ConvexPolygonShape3D:
		corners = (shape as ConvexPolygonShape3D).points
	for corner in corners:
		var point := placement * corner
		points.append(Vector2(point.x, point.z))
	return Geometry2D.convex_hull(points)


## Height of its highest visible point in the world.
func get_top() -> float:
	if not is_nan(_batched_top):
		return _batched_top
	var top := -INF
	for child in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh != null and mesh_instance.visible:
			top = maxf(top, (mesh_instance.global_transform * mesh_instance.get_aabb()).end.y)
	return top


## Hands its meshes to a MapPropBatch, which draws the props of a kind as MultiMesh
## instances: returns {mesh, materials, transform, shadow} per mesh (world transforms) and
## frees the nodes. The prop keeps its collision footprint, and its height for the fog of war.
func take_visuals() -> Array[Dictionary]:
	_batched_top = get_top()
	var parts: Array[Dictionary] = []
	for child in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh == null or not mesh_instance.visible:
			continue
		var materials: Array[Material] = []
		for surface in mesh_instance.mesh.get_surface_count():
			materials.append(mesh_instance.get_active_material(surface))
		parts.append({"mesh": mesh_instance.mesh, "materials": materials,
				"transform": mesh_instance.global_transform, "shadow": mesh_instance.cast_shadow})
		mesh_instance.get_parent().remove_child(mesh_instance)
		mesh_instance.queue_free()
	return parts


## Builds generated visuals; props whose visuals are their children do nothing.
func _build_visual() -> void:
	pass


## Sets `_collision`'s shape and position to wrap the prop, with the prop's scale
## already applied (`scaling`): the body itself is kept unscaled for physics.
func _fit_collision(scaling: Vector3) -> void:
	var points := PackedVector3Array()
	for point in _mesh_points():
		points.append(point * scaling)
	if points.is_empty():
		_collision.shape = null
		return
	var bounds := AABB(points[0], Vector3.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	var center := bounds.get_center()
	var squeeze := Vector3(footprint_scale, 1.0, footprint_scale)
	_collision.position = Vector3(center.x, 0.0, center.z)
	match footprint:
		Footprint.BOX:
			var box := BoxShape3D.new()
			box.size = bounds.size * squeeze
			_collision.shape = box
			_collision.position = center
		Footprint.CYLINDER:
			var radius := 0.0
			for point in points:
				radius = maxf(radius, Vector2(point.x - center.x, point.z - center.z).length())
			var cylinder := CylinderShape3D.new()
			cylinder.radius = radius * footprint_scale
			cylinder.height = bounds.size.y
			_collision.shape = cylinder
			_collision.position = center
		Footprint.CONVEX_HULL:
			var hull := ConvexPolygonShape3D.new()
			var squeezed := PackedVector3Array()
			for point in points:
				squeezed.append((point - Vector3(center.x, 0.0, center.z)) * squeeze)
			hull.points = squeezed
			_collision.shape = hull


func _build_collision() -> void:
	if not blocks_movement:
		remove_from_group(NAVIGATION_GROUP)
		if _body != null:
			_body.queue_free()
			_body = null
			_collision = null
		return
	add_to_group(NAVIGATION_GROUP)
	if _body == null:
		# Not owned by the scene: generated on load, never saved, not in the Scene dock
		_body = StaticBody3D.new()
		_body.name = &"_Collision"
		_body.collision_layer = LAYER_WORLD
		_body.collision_mask = 0
		_collision = CollisionShape3D.new()
		_body.add_child(_collision)
		add_child(_body)
	var scaling := basis.get_scale().abs()
	_fit_collision(scaling)
	_built_scale = scaling
	_place_body()
	update_gizmos()


## Keeps the collision body unscaled and down on the gameplay plane, however high the
## prop stands on the terrain.
func _place_body() -> void:
	if _body == null or not is_inside_tree():
		return
	var scaling := basis.get_scale().abs()
	var drop := (GROUND_HEIGHT - global_position.y) / maxf(scaling.y, 0.0001)
	_body.transform = Transform3D(Basis.from_scale(Vector3.ONE / scaling), Vector3(0.0, drop, 0.0))


## Every mesh vertex under the prop, in the prop's own (unscaled) space.
func _mesh_points() -> PackedVector3Array:
	var points := PackedVector3Array()
	var to_prop := global_transform.affine_inverse()
	for child in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh == null or not mesh_instance.visible:
			continue
		var mesh_to_prop := to_prop * mesh_instance.global_transform
		var seen: Dictionary[Vector3i, bool] = {}
		for vertex in mesh_instance.mesh.get_faces():
			var key := Vector3i((vertex * 100.0).round())
			if not seen.has(key):
				seen[key] = true
				points.append(mesh_to_prop * vertex)
	return points


## Upright on the drawn ground, keeping the yaw and scale the editor gave it.
func _settle() -> void:
	var now := global_transform
	var yaw := now.basis.orthonormalized().get_euler().y
	var upright := Basis.from_euler(Vector3(0.0, yaw, 0.0)) * Basis.from_scale(now.basis.get_scale().abs())
	var ground := GROUND_HEIGHT + Terrain.ground(now.origin.x, now.origin.z)
	var settled := Transform3D(upright, Vector3(now.origin.x, ground, now.origin.z))
	if not settled.is_equal_approx(now):
		global_transform = settled
	_place_body()
