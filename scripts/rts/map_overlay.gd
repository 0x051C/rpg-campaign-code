class_name MapOverlay
extends Control

## Diablo-style overlay map, toggled with rts_map_overlay (Z): a see-through map
## drawn over the game around the camera's look-at point, turned like the camera.
## It shows the outline of the walkable area, the creep lanes, what the camera sees,
## the player's heroes and summons with their experience range, creeps that are
## fighting or within experience range of a hero, and every MapMarker (quests,
## objectives, dropped items, points of interest). Markers off the map point at
## themselves from its edge.

const OUTLINE_COLOR := Color(0.55, 0.75, 1.0, 0.8)
const LANE_COLOR := Color(1.0, 0.9, 0.6, 0.18)
const VIEW_COLOR := Color(1.0, 1.0, 1.0, 0.4)
const RANGE_COLOR := Color(0.35, 1.0, 0.45, 0.1)
const HERO_COLOR := Color(0.35, 1.0, 0.45)
const ALLY_COLOR := Color(0.4, 0.7, 1.0)
const ENEMY_COLOR := Color(1.0, 0.3, 0.25)
const COMBAT_COLOR := Color(1.0, 0.85, 0.3, 0.9)
const EDGE_MARGIN := 36.0
const OUTLINE_CHUNK := 32.0  ## meters: the outline is split into squares this size, so off-screen ones are culled
const FONT_SIZE := 14

@export var commander: Commander
@export var registry: UnitRegistry
@export var camera: RTSCamera
@export var navigation: NavigationRegion3D
## Meters of map from the top of the screen to the bottom.
@export var meters_shown :=  50
## How much the game behind the map is darkened.
@export_range(0.0, 1.0) var dim := 0.3

var _outline := PackedVector2Array()  ## the walkable area's border as world XZ segments, traced once
var _center := Vector3.ZERO
var _pixels_per_meter := 1.0
var _turn := 0.0
# Drawn behind the overlay's own drawing: the dim backdrop, then the outline. The outline is
# drawn once in world meters, in OUTLINE_CHUNK squares (one canvas item each, so the ones off
# screen are culled), and only moved, turned and scaled with the camera: redrawing thousands of
# border points every frame was most of the overlay's cost on big maps.
var _backdrop := ColorRect.new()
var _outline_layer := Node2D.new()
var _outline_scale := 0.0  ## pixels per meter the outline was last drawn at (its line width depends on it)


func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	_backdrop.color = Color(0, 0, 0, dim)
	_backdrop.mouse_filter = MOUSE_FILTER_IGNORE
	_backdrop.show_behind_parent = true
	_backdrop.set_anchors_preset(PRESET_FULL_RECT)
	add_child(_backdrop)
	_outline_layer.show_behind_parent = true
	add_child(_outline_layer)
	if navigation != null:
		navigation.bake_finished.connect(_trace_outline)
	set_process(visible)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"rts_map_overlay"):
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	set_process(visible)
	if visible and _outline.is_empty():
		_trace_outline()
	queue_redraw()
	_place_outline()


func _process(_delta: float) -> void:
	queue_redraw()
	_place_outline()


## Where a world point lands on the overlay.
func to_map(world: Vector3) -> Vector2:
	var offset := Vector2(world.x - _center.x, world.z - _center.z).rotated(_turn)
	return size * 0.5 + offset * _pixels_per_meter


func _trace_outline() -> void:
	_outline.clear()
	if navigation == null or navigation.navigation_mesh == null:
		return
	for point in NavOutline.of(navigation.navigation_mesh).border:
		var world := navigation.global_transform * point
		_outline.append(Vector2(world.x, world.z))
	for chunk in _outline_layer.get_children():
		chunk.queue_free()
	var chunks := {}  # square -> its segments
	for i in range(0, _outline.size() - 1, 2):
		var square := Vector2i(((_outline[i] + _outline[i + 1]) * 0.5 / OUTLINE_CHUNK).floor())
		if not chunks.has(square):
			chunks[square] = PackedVector2Array()
		chunks[square].append(_outline[i])
		chunks[square].append(_outline[i + 1])
	for square: Vector2i in chunks:
		var chunk := Node2D.new()
		var segments: PackedVector2Array = chunks[square]
		chunk.draw.connect(func() -> void:
			chunk.draw_multiline(segments, OUTLINE_COLOR, 2.0 / maxf(_outline_scale, 0.001), true))
		_outline_layer.add_child(chunk)


## Where the camera is and how the map turns, for to_map(); the outline layer follows it whole.
func _place_outline() -> void:
	_center = camera.global_position
	_pixels_per_meter = size.y / meters_shown
	_turn = deg_to_rad(camera.yaw)  # the camera's forward points up the map
	# to_map(world) = size / 2 + rotated(world.xz - center.xz) * pixels per meter, as one transform
	var place := Transform2D(_turn, Vector2(_pixels_per_meter, _pixels_per_meter), 0.0, Vector2.ZERO)
	place.origin = size * 0.5 - place.basis_xform(Vector2(_center.x, _center.z))
	_outline_layer.transform = place
	if not is_equal_approx(_outline_scale, _pixels_per_meter):
		_outline_scale = _pixels_per_meter  # the lines' width is in meters: 2 pixels at this scale
		for chunk: Node2D in _outline_layer.get_children():
			chunk.queue_redraw()


func _draw() -> void:
	_draw_lanes()
	_draw_view()
	_draw_units()
	_draw_markers()
	var font := ThemeDB.fallback_font
	var title := "MAP  (Z)"
	var width := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE + 2).x
	_text(Vector2(size.x - width - 16.0, 26.0), title, Color(1, 1, 1, 0.8), FONT_SIZE + 2)


func _draw_lanes() -> void:
	for spawner: CreepSpawner in get_tree().get_nodes_in_group(&"creep_spawners"):
		if not spawner.has_lane():
			continue  # a NeutralCamp: no lane to draw
		var points := PackedVector2Array([to_map(spawner.global_position)])
		for lane_node in spawner.lane_nodes:
			points.append(to_map(lane_node.global_position))
		draw_polyline(points, LANE_COLOR, 6.0, true)


## The ground the camera sees, like a minimap's view frame.
func _draw_view() -> void:
	var view := camera.camera
	var screen := view.get_viewport().get_visible_rect().size
	var ground := Plane(Vector3.UP, 0.0)
	var corners := PackedVector2Array()
	for corner in [Vector2.ZERO, Vector2(screen.x, 0.0), screen, Vector2(0.0, screen.y), Vector2.ZERO]:
		var hit: Variant = ground.intersects_ray(view.project_ray_origin(corner), view.project_ray_normal(corner))
		if hit == null:
			return
		corners.append(to_map(hit))
	draw_polyline(corners, VIEW_COLOR, 1.5, true)


## Where the player's living heroes are.
func hero_positions() -> Array[Vector3]:
	var heroes: Array[Vector3] = []
	var positions := registry.vec3_column(UnitRegistry.Kind.HERO, "position")
	var teams := registry.int_column(UnitRegistry.Kind.HERO, "team")
	for i in positions.size():
		if teams[i] == registry.player_team:
			heroes.append(positions[i])
	return heroes


## A creep shows on the map while it fights, or while a hero would get experience
## for killing it.
func is_creep_shown(handle: int, heroes: Array[Vector3]) -> bool:
	return registry.is_alive(registry.target_of(handle)) or _near_any(registry.position_of(handle), heroes, UnitRegistry.EXPERIENCE_RANGE)


func _draw_units() -> void:
	var heroes := hero_positions()
	for hero in heroes:
		draw_arc(to_map(hero), UnitRegistry.EXPERIENCE_RANGE * _pixels_per_meter, 0.0, TAU, 64, RANGE_COLOR, 1.5, true)

	# The player's heroes and summons as arrows
	for kind in [UnitRegistry.Kind.HERO, UnitRegistry.Kind.SUMMON]:
		var own := registry.handles(kind)
		var spots := registry.vec3_column(kind, "position")
		var yaws := registry.float_column(kind, "yaw")
		var sides := registry.int_column(kind, "team")
		for i in own.size():
			if sides[i] == registry.player_team:
				_arrow(to_map(spots[i]), yaws[i], 9.0 if kind == UnitRegistry.Kind.HERO else 6.0, HERO_COLOR,
						own[i] in commander.control_selection)

	# Creeps fighting or near a hero; villagers always
	var ids := registry.handles(UnitRegistry.Kind.NPC)
	var positions := registry.vec3_column(UnitRegistry.Kind.NPC, "position")
	var teams := registry.int_column(UnitRegistry.Kind.NPC, "team")
	var sighted := registry.int_column(UnitRegistry.Kind.NPC, "sighted")
	var targets := registry.int_column(UnitRegistry.Kind.NPC, "target")
	var types := registry.int_column(UnitRegistry.Kind.NPC, "definition")
	for i in ids.size():
		var at := to_map(positions[i])
		if teams[i] == UnitRegistry.NEUTRAL_TEAM:
			draw_circle(at, 3.5, Commander.COLOR_NEUTRAL, true, -1.0, true)  # villagers are always shown
			continue
		var fighting := registry.is_alive(targets[i])
		if not (fighting or _near_any(positions[i], heroes, UnitRegistry.EXPERIENCE_RANGE)) \
				or not UnitRegistry.sees_bits(registry.player_team, teams[i], sighted[i]):
			continue
		var radius := 4.5 if registry.definitions[types[i]].siege else 3.5
		if fighting:
			draw_arc(at, radius + 2.5, 0.0, TAU, 12, COMBAT_COLOR, 1.5, true)
		draw_circle(at, radius, ALLY_COLOR if teams[i] == registry.player_team else ENEMY_COLOR, true, -1.0, true)


func _draw_markers() -> void:
	var area := Rect2(Vector2.ZERO, size).grow(-EDGE_MARGIN)
	for marker: MapMarker in get_tree().get_nodes_in_group(MapMarker.GROUP):
		if not marker.is_visible_in_tree():
			continue
		var at := to_map(marker.global_position)
		var color := marker.get_color()
		if area.has_point(at):
			_marker_icon(marker, at, color)
			if not marker.title.is_empty():
				_text(at + Vector2(11.0, 5.0), marker.title, color, FONT_SIZE)
			continue
		# Off the map: pin it to the edge, pointing the way
		var middle := size * 0.5
		var direction := (at - middle).normalized()
		var reach := minf(
			absf(area.size.x * 0.5 / direction.x) if not is_zero_approx(direction.x) else INF,
			absf(area.size.y * 0.5 / direction.y) if not is_zero_approx(direction.y) else INF)
		var pinned := middle + direction * reach
		_marker_icon(marker, pinned, color)
		var tip := pinned + direction * 16.0
		var side := direction.orthogonal() * 5.0
		draw_colored_polygon(PackedVector2Array([tip, pinned + direction * 9.0 + side, pinned + direction * 9.0 - side]), color)


func _marker_icon(marker: MapMarker, at: Vector2, color: Color) -> void:
	match marker.kind:
		MapMarker.Kind.QUEST, MapMarker.Kind.OBJECTIVE:
			draw_circle(at, 8.0, Color(0, 0, 0, 0.6), true, -1.0, true)
			draw_circle(at, 8.0, color, false, 2.0, true)
			var symbol := marker.get_symbol()
			var font := ThemeDB.fallback_font
			var width := font.get_string_size(symbol, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
			draw_string(font, at + Vector2(-width * 0.5, 5.0), symbol, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, color)
		MapMarker.Kind.ITEM:
			var diamond := PackedVector2Array([at + Vector2(0, -6), at + Vector2(5, 0), at + Vector2(0, 6), at + Vector2(-5, 0)])
			draw_colored_polygon(diamond, color)
			diamond.append(diamond[0])
			draw_polyline(diamond, Color(0, 0, 0, 0.8), 1.0, true)
		MapMarker.Kind.POINT_OF_INTEREST:
			draw_circle(at, 5.0, color, false, 2.0, true)
			draw_circle(at, 1.5, color, true, -1.0, true)


func _arrow(at: Vector2, yaw: float, length: float, color: Color, selected: bool) -> void:
	# Units face +Z at yaw 0; turn that into a map direction
	var facing := Vector2(sin(yaw), cos(yaw)).rotated(_turn)
	var side := facing.orthogonal() * length * 0.55
	var points := PackedVector2Array([at + facing * length, at - facing * length * 0.6 + side, at - facing * length * 0.6 - side])
	draw_colored_polygon(points, color)
	if selected:
		points.append(points[0])
		draw_polyline(points, Color.WHITE, 1.5, true)


func _text(at: Vector2, text: String, color: Color, font_size: int) -> void:
	var font := ThemeDB.fallback_font
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color(0, 0, 0, 0.9))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


static func _near_any(point: Vector3, others: Array[Vector3], reach: float) -> bool:
	for other in others:
		if Vector2(point.x - other.x, point.z - other.z).length() <= reach:
			return true
	return false
