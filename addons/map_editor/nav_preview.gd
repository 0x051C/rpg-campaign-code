@tool
extends Node3D

## Editor overlay for a map: the navigation mesh the game will bake at startup
## (walkable area in green, pockets units can't reach from the main area in red,
## and the edges where walking stops) plus every creep spawner's lane. It bakes a
## copy of the region's NavigationMesh, so the scene file never stores baked data.
## The navigation mesh is flat (gameplay is 2D); its drawing is cut into small pieces
## that the ground decal shader lays over the terrain.

signal baked

const NODE_NAME := &"_MapEditorPreview"
const LIFT := 0.08
const LANE_LIFT := 0.2
const WALKABLE_COLOR := Color(0.3, 0.9, 0.4, 0.1)
const ISLAND_COLOR := Color(1.0, 0.25, 0.2, 0.55)
const EDGE_COLOR := Color(0.65, 1.0, 0.7, 0.9)
const TEAM_COLORS: Dictionary[int, Color] = {1: Color(0.35, 0.65, 1.0), 2: Color(1.0, 0.4, 0.3)}
const PIECE := 2.0  ## meters: longest edge drawn before the terrain can bend it
const GROUND_DECAL := preload("res://shaders/ground_decal.gdshader")

## Results of the last bake.
var outline: NavOutline
var baked_mesh: NavigationMesh

var _fill := MeshInstance3D.new()
var _edges := MeshInstance3D.new()
var _lanes := MeshInstance3D.new()
var _baking := false
var _queued: NavigationRegion3D


func _init() -> void:
	name = NODE_NAME
	for part: MeshInstance3D in [_fill, _edges, _lanes]:
		part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		part.material_override = _overlay_material()
		add_child(part)
	_lanes.top_level = true  # spawners are in scene space, not the region's


## Rebakes the preview for `region` and redraws the lanes of the spawners under `root`.
func refresh(region: NavigationRegion3D, root: Node) -> void:
	_draw_lanes(root)
	if region == null or region.navigation_mesh == null:
		_fill.mesh = null
		_edges.mesh = null
		return
	if _baking:
		_queued = region
		return
	_bake(region)


func is_baking() -> bool:
	return _baking or _queued != null


func _bake(region: NavigationRegion3D) -> void:
	_baking = true
	var navigation_mesh: NavigationMesh = region.navigation_mesh.duplicate()
	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(navigation_mesh, source, region)
	var done := func() -> void: _on_baked.call_deferred(region, navigation_mesh)
	NavigationServer3D.bake_from_source_geometry_data_async(navigation_mesh, source, done)


func _on_baked(region: NavigationRegion3D, navigation_mesh: NavigationMesh) -> void:
	_baking = false
	if _queued != null:
		var next := _queued
		_queued = null
		if is_instance_valid(next):
			_bake(next)
	if not is_instance_valid(region) or not is_inside_tree():
		return
	global_transform = region.global_transform
	baked_mesh = navigation_mesh
	outline = NavOutline.of(navigation_mesh)
	_draw_navigation(navigation_mesh)
	baked.emit()


func _draw_navigation(navigation_mesh: NavigationMesh) -> void:
	var vertices := navigation_mesh.get_vertices()
	var lift := Vector3.UP * LIFT
	var fill := SurfaceTool.new()
	fill.begin(Mesh.PRIMITIVE_TRIANGLES)
	for p in outline.polygon_count:
		var polygon := navigation_mesh.get_polygon(p)
		var color := WALKABLE_COLOR if outline.reachable[p] else ISLAND_COLOR
		for i in range(1, polygon.size() - 1):
			_add_triangle(fill, vertices[polygon[0]] + lift, vertices[polygon[i]] + lift, vertices[polygon[i + 1]] + lift, color)
	_fill.mesh = fill.commit() if outline.polygon_count > 0 else null

	var border := PackedVector3Array()
	var colors := PackedColorArray()
	for i in range(0, outline.border.size() - 1, 2):
		_add_line(border, colors, outline.border[i] + lift, outline.border[i + 1] + lift, EDGE_COLOR)
	_edges.mesh = _line_mesh(border, colors)


## Splits a triangle until its edges are short enough to follow the terrain.
static func _add_triangle(fill: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color: Color) -> void:
	var ab := a.distance_to(b)
	var bc := b.distance_to(c)
	var ca := c.distance_to(a)
	var longest := maxf(ab, maxf(bc, ca))
	if longest <= PIECE:
		for corner in [a, b, c]:
			fill.set_color(color)
			fill.add_vertex(corner)
		return
	if longest == ab:
		var middle := (a + b) * 0.5
		_add_triangle(fill, a, middle, c, color)
		_add_triangle(fill, middle, b, c, color)
	elif longest == bc:
		var middle := (b + c) * 0.5
		_add_triangle(fill, a, b, middle, color)
		_add_triangle(fill, a, middle, c, color)
	else:
		var middle := (c + a) * 0.5
		_add_triangle(fill, a, b, middle, color)
		_add_triangle(fill, middle, b, c, color)


static func _add_line(points: PackedVector3Array, colors: PackedColorArray, from: Vector3, to: Vector3, color: Color) -> void:
	var count := maxi(1, ceili(from.distance_to(to) / PIECE))
	for i in count:
		points.append_array([from.lerp(to, float(i) / count), from.lerp(to, float(i + 1) / count)])
		colors.append_array([color, color])


func _draw_lanes(root: Node) -> void:
	var points := PackedVector3Array()
	var colors := PackedColorArray()
	if root != null:
		for spawner in root.find_children("*", "Marker3D"):
			if not spawner is CreepSpawner:
				continue
			var color: Color = TEAM_COLORS.get(spawner.get(&"team"), Color.WHITE)
			var previous := (spawner as Node3D).global_position
			for entry in spawner.get(&"lane_nodes"):
				# A script that isn't @tool may hold node exports as paths in the editor
				var lane_node: Node3D = entry if entry is Node3D else spawner.get_node_or_null(entry) as Node3D
				if lane_node == null:
					continue
				var from := Vector3(previous.x, LANE_LIFT, previous.z)
				_add_line(points, colors, from, Vector3(lane_node.global_position.x, LANE_LIFT, lane_node.global_position.z), color)
				previous = lane_node.global_position
	_lanes.mesh = _line_mesh(points, colors)


static func _line_mesh(points: PackedVector3Array, colors: PackedColorArray) -> ArrayMesh:
	if points.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


static func _overlay_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = GROUND_DECAL
	material.set_shader_parameter(&"use_instance_color", true)  # vertex colors, sRGB
	material.render_priority = 1
	return material
