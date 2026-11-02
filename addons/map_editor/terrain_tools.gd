@tool
extends RefCounted

## Terrain brushes for the Map Editor: sculpt heights and paint tiles with the left mouse
## button in the 3D view; each stroke is one undo step. A ring shows the brush on the ground.
##   Raise / Lower: hold Ctrl for the other one. Shift with any sculpt tool smooths.
##   Flatten levels toward the height under the cursor where the stroke started.
##   Paint sets the selected tile; Ctrl+click picks the tile under the cursor.
## Also whole-terrain operations: add a terrain, generate hills, import/export heightmaps.

signal tile_picked(tile: int)
## A linked heightmap file was reloaded (or couldn't be): the message for the dock.
signal heightmap_synced(message: String)

enum Tool { NONE, RAISE, LOWER, SMOOTH, FLATTEN, NOISE, PAINT }

const TOOL_NAMES: Dictionary[Tool, String] = {
	Tool.RAISE: "Raise", Tool.LOWER: "Lower", Tool.SMOOTH: "Smooth",
	Tool.FLATTEN: "Flatten", Tool.NOISE: "Noise", Tool.PAINT: "Paint",
}
const TOOL_COLORS: Dictionary[Tool, Color] = {
	Tool.RAISE: Color(0.4, 1.0, 0.5), Tool.LOWER: Color(1.0, 0.45, 0.4), Tool.SMOOTH: Color(0.45, 0.75, 1.0),
	Tool.FLATTEN: Color(1.0, 0.85, 0.35), Tool.NOISE: Color(0.8, 0.55, 1.0), Tool.PAINT: Color(1.0, 1.0, 1.0),
}
const BRUSH_NAME := &"_TerrainBrush"
const DAB_SPACING := 0.2  ## of the radius, between dabs while dragging
const DAB_RATE := 15.0  ## dabs per second while the button is held still
const HEIGHTMAP_POLL_TIME := 0.5  ## seconds between looks at a linked heightmap file
const RISE_PER_DAB := 0.12  ## meters, at full strength
const GROUND_DECAL := preload("res://shaders/ground_decal.gdshader")

var tool := Tool.NONE:
	set(value):
		tool = value
		_update_brush()
var radius := 4.0
var strength := 0.5
var tile := 0

var _plugin: EditorPlugin
var _terrain: Terrain
var _cursor := Vector3.INF
var _stroking := false
var _stroke_tool := Tool.NONE
var _before_heights := PackedFloat32Array()
var _before_tiles := PackedByteArray()
var _flatten_height := 0.0
var _last_dab := Vector3.INF
var _dab_timer := 0.0
var _poll_timer := 0.0
var _noise := FastNoiseLite.new()
var _brush: MeshInstance3D
var _brush_material := ShaderMaterial.new()


func _init(plugin: EditorPlugin) -> void:
	_plugin = plugin
	_noise.frequency = 0.18
	_brush_material.shader = GROUND_DECAL
	_brush_material.render_priority = 2


## The terrain of the edited scene, if it has one.
func find_terrain() -> Terrain:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	if root is Terrain:
		return root
	for node in root.find_children("*", "Node3D", true, false):
		if node is Terrain:
			return node
	return null


## Handles a 3D view event; true when the brush used it.
func handle(camera: Camera3D, event: InputEvent) -> bool:
	if tool == Tool.NONE:
		return false
	_terrain = find_terrain()
	if _terrain == null or _terrain.data == null:
		return false
	var mouse := event as InputEventMouse
	if mouse == null:
		return false
	_cursor = _terrain.raycast(camera.project_ray_origin(_view_point(camera, mouse.position)),
			camera.project_ray_normal(_view_point(camera, mouse.position)))
	_update_brush()
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		if button.pressed:
			if _cursor == Vector3.INF:
				return true
			if tool == Tool.PAINT and button.ctrl_pressed:
				tile = _terrain.tile_at(_cursor.x, _cursor.z)
				tile_picked.emit(tile)
				return true
			_begin_stroke(button)
		else:
			_end_stroke()
		return true
	if _stroking and _cursor != Vector3.INF and _cursor.distance_to(_last_dab) >= radius * DAB_SPACING:
		_dab(_cursor)
	return false  # motion also drives the RTS view


## Keeps dabbing while the button is held still (sculpting only), and follows a linked
## heightmap file that was saved in an image editor.
func process(delta: float) -> void:
	_poll_timer -= delta
	if _poll_timer <= 0.0 and not _stroking:
		_poll_timer = HEIGHTMAP_POLL_TIME
		var message := sync_heightmap()
		if not message.is_empty():
			heightmap_synced.emit(message)
	if not _stroking or _stroke_tool == Tool.PAINT or _cursor == Vector3.INF:
		return
	_dab_timer += delta
	while _dab_timer >= 1.0 / DAB_RATE:
		_dab_timer -= 1.0 / DAB_RATE
		_dab(_cursor)


func cleanup() -> void:
	if is_instance_valid(_brush):
		_brush.queue_free()
	_brush = null


# --- Whole-terrain operations --------------------------------------------------

## Adds a flat terrain to the edited scene; its data is saved next to the scene. Undoable.
func add_terrain(cells: Vector2i) -> Terrain:
	var root := EditorInterface.get_edited_scene_root()
	if root == null or not root is Node3D or find_terrain() != null:
		return null
	var data := TerrainData.create(cells, 1.0, 0)
	var scene_path := root.scene_file_path
	if not scene_path.is_empty():
		var data_path := scene_path.get_basename() + "_terrain.res"
		ResourceSaver.save(data, data_path)
		data.take_over_path(data_path)
	var terrain := Terrain.new()
	terrain.name = &"Terrain"
	terrain.tileset = load("res://data/terrain/default_tileset.tres")
	terrain.data = data
	var parent: Node = root
	var regions := root.find_children("*", "NavigationRegion3D", true, false)
	if not regions.is_empty():
		parent = regions[0]
	var undo := _plugin.get_undo_redo()
	undo.create_action("Add Terrain")
	undo.add_do_method(parent, &"add_child", terrain, true)
	undo.add_do_method(terrain, &"set_owner", root)
	undo.add_do_reference(terrain)
	undo.add_undo_method(parent, &"remove_child", terrain)
	undo.commit_action()
	return terrain


## Replaces the heights with fractal noise hills. `flat_center` keeps a calm middle (0..1 of
## the half size) for a playable area. Undoable.
func generate(seed_value: int, height: float, feature_meters: float, octaves: int, flat_center: float) -> void:
	var terrain := find_terrain()
	if terrain == null:
		return
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 1.0 / maxf(feature_meters, 0.5)
	noise.fractal_octaves = octaves
	var data := terrain.data
	var heights := data.heights.duplicate()
	var half := Vector2(data.size) * 0.5
	for z in data.size.y + 1:
		for x in data.size.x + 1:
			var meters := Vector2(x, z) * data.cell_size
			var value := (noise.get_noise_2dv(meters) * 0.5 + 0.5) * height
			if flat_center > 0.0:
				var from_center := ((Vector2(x, z) - half) / half).length()
				value *= smoothstep(flat_center * 0.8, flat_center, from_center)
			heights[data.index(x, z)] = value
	_replace(terrain, "Generate Terrain", heights, data.tiles)


## Fits a grayscale image to the terrain: black = `low` meters, white = `high`. Undoable.
func import_heightmap(path: String, low: float, high: float) -> String:
	var terrain := find_terrain()
	if terrain == null:
		return "No terrain in this scene"
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return "Can't read %s" % path
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RF)
	var vertices := terrain.data.vertices()
	image.resize(vertices.x, vertices.y, Image.INTERPOLATE_CUBIC)
	var heights := terrain.data.heights.duplicate()
	for z in vertices.y:
		for x in vertices.x:
			heights[terrain.data.index(x, z)] = lerpf(low, high, clampf(image.get_pixel(x, z).r, 0.0, 1.0))
	_replace(terrain, "Import Heightmap", heights, terrain.data.tiles)
	return ""


## Writes the heights as an image: .exr keeps meters exactly; .png is scaled to its own range.
func export_heightmap(path: String) -> String:
	var terrain := find_terrain()
	if terrain == null:
		return "No terrain in this scene"
	var data := terrain.data
	var vertices := data.vertices()
	var image := Image.create_from_data(vertices.x, vertices.y, false, Image.FORMAT_RF, data.heights.to_byte_array())
	if path.get_extension().to_lower() == "exr":
		return "" if image.save_exr(path, true) == OK else "Can't write %s" % path
	var low := INF
	var high := -INF
	for h in data.heights:
		low = minf(low, h)
		high = maxf(high, h)
	var gray := Image.create(vertices.x, vertices.y, false, Image.FORMAT_L8)
	for z in vertices.y:
		for x in vertices.x:
			var value := inverse_lerp(low, high, data.heights[data.index(x, z)]) if high > low else 0.0
			gray.set_pixel(x, z, Color(value, value, value))
	return "" if gray.save_png(path) == OK else "Can't write %s" % path


## Saves the edited scene's terrain data if it lives in its own file, and writes sculpted
## heights back to a linked heightmap file.
func save_data() -> void:
	var terrain := find_terrain()
	if terrain == null or terrain.data == null:
		return
	var data := terrain.data
	if not data.heightmap.is_empty() and hash(data.heights) != data.heightmap_hash:
		var error := HeightmapFile.write(data.heightmap, data.heights, data.vertices(), data.heightmap_low, data.heightmap_high)
		if error.is_empty():
			_mark_synced(data)
		else:
			push_warning(error)
	var path := data.resource_path
	if not path.is_empty() and not path.contains("::"):
		ResourceSaver.save(data, path)


# --- Heightmap file link -------------------------------------------------------

## Links the terrain to the image at `path`. An existing image becomes the heights
## (undoable); otherwise the current heights are written to it, black = `low` and white =
## `high` meters (widened to fit them). Returns what happened.
func link_heightmap(path: String, low: float, high: float) -> String:
	var terrain := find_terrain()
	if terrain == null or terrain.data == null:
		return "No terrain in this scene"
	var data := terrain.data
	var existed := FileAccess.file_exists(path)
	if not existed:
		var bounds := _height_bounds(data.heights)
		low = minf(low, floorf(bounds.x))
		high = maxf(high, ceilf(bounds.y))
	data.heightmap = path
	data.heightmap_low = low
	data.heightmap_high = high
	if existed:
		var read := HeightmapFile.read(path, data.vertices(), low, high)
		if read.has("error"):
			data.heightmap = ""
			return read.error
		_replace(terrain, "Link Heightmap", read.heights, data.tiles)
	else:
		var error := HeightmapFile.write(path, data.heights, data.vertices(), low, high)
		if not error.is_empty():
			data.heightmap = ""
			return error
		_keep_unimported(path)
	_mark_synced(data)
	save_data()
	EditorInterface.get_resource_filesystem().scan()
	return "%s %s: black %.1f m, white %.1f m. Paint it and save; the terrain follows." % [
			"Linked" if existed else "Wrote", path.get_file(), low, high]


func unlink_heightmap() -> void:
	var terrain := find_terrain()
	if terrain != null and terrain.data != null:
		terrain.data.heightmap = ""
		save_data()


## New black and white heights for the linked file: rereads it (undoable).
func set_heightmap_range(low: float, high: float) -> String:
	var terrain := find_terrain()
	if terrain == null or terrain.data == null or terrain.data.heightmap.is_empty():
		return ""
	terrain.data.heightmap_low = low
	terrain.data.heightmap_high = high
	terrain.data.heightmap_time = 0  # reread now
	return sync_heightmap()


## Reloads a linked heightmap file that changed since it was last read or written
## (undoable). Returns what happened, or "" when nothing did.
func sync_heightmap() -> String:
	var terrain := find_terrain()
	if terrain == null or terrain.data == null or terrain.data.heightmap.is_empty():
		return ""
	var data := terrain.data
	var path := data.heightmap
	if not FileAccess.file_exists(path):
		return ""
	var time := FileAccess.get_modified_time(path)
	if time == data.heightmap_time:
		return ""
	var read := HeightmapFile.read(path, data.vertices(), data.heightmap_low, data.heightmap_high)
	data.heightmap_time = time  # a broken save isn't retried until the file changes again
	if read.has("error"):
		return read.error
	_replace(terrain, "Heightmap File Changed", read.heights, data.tiles)
	_mark_synced(data)
	save_data()
	return "Reloaded %s. Ctrl+Z undoes it." % path.get_file()


func _mark_synced(data: TerrainData) -> void:
	data.heightmap_time = FileAccess.get_modified_time(data.heightmap)
	data.heightmap_hash = hash(data.heights)


## Imports the file as-is ("Keep File"): Godot needn't make a texture of it on every save.
static func _keep_unimported(path: String) -> void:
	var import_file := FileAccess.open(path + ".import", FileAccess.WRITE)
	if import_file != null:
		import_file.store_string('[remap]\n\nimporter="keep"\n')


static func _height_bounds(heights: PackedFloat32Array) -> Vector2:
	var low := INF
	var high := -INF
	for h in heights:
		low = minf(low, h)
		high = maxf(high, h)
	return Vector2(low, high) if low <= high else Vector2.ZERO


# --- Strokes -------------------------------------------------------------------

func _begin_stroke(button: InputEventMouseButton) -> void:
	_stroking = true
	_stroke_tool = tool
	if button.shift_pressed and tool != Tool.PAINT:
		_stroke_tool = Tool.SMOOTH
	elif button.ctrl_pressed and tool == Tool.RAISE:
		_stroke_tool = Tool.LOWER
	elif button.ctrl_pressed and tool == Tool.LOWER:
		_stroke_tool = Tool.RAISE
	_before_heights = _terrain.data.heights.duplicate()
	_before_tiles = _terrain.data.tiles.duplicate()
	_flatten_height = _terrain.height_at(_cursor.x, _cursor.z)
	_dab_timer = 0.0
	_terrain.begin_stroke()  # dabs refresh only what's under the brush until the stroke ends
	_dab(_cursor)


func _end_stroke() -> void:
	if not _stroking:
		return
	_stroking = false
	if _terrain == null or not is_instance_valid(_terrain):
		return
	_terrain.end_stroke()
	var data := _terrain.data
	if data.heights == _before_heights and data.tiles == _before_tiles:
		return
	var undo := _plugin.get_undo_redo()
	undo.create_action("Terrain %s" % TOOL_NAMES[_stroke_tool], UndoRedo.MERGE_DISABLE, _terrain)
	undo.add_do_method(_terrain, &"set_arrays", data.heights.duplicate(), data.tiles.duplicate())
	undo.add_undo_method(_terrain, &"set_arrays", _before_heights, _before_tiles)
	undo.commit_action(false)  # the strokes already applied it


## One application of the brush at `center`.
func _dab(center: Vector3) -> void:
	_last_dab = center
	var data := _terrain.data
	var at := _terrain.vertex_coords(center)
	var reach := radius / data.cell_size
	var low := Vector2i((at - Vector2(reach, reach)).floor())
	var high := Vector2i((at + Vector2(reach, reach)).ceil()) + Vector2i.ONE
	var rect := Rect2i(low, high - low).intersection(Rect2i(Vector2i.ZERO, data.vertices()))
	if not rect.has_area():
		return
	if _stroke_tool == Tool.PAINT:
		var tiles := data.tiles  # edited locally, assigned back once
		for z in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				if Vector2(x, z).distance_to(at) <= reach:
					tiles[data.index(x, z)] = tile
		data.tiles = tiles
		_terrain.commit_tiles(rect)
		return

	var heights := data.heights  # edited locally, assigned back once
	var source := heights.duplicate() if _stroke_tool == Tool.SMOOTH else heights  # smoothing reads the heights from before this dab
	var last := data.vertices() - Vector2i.ONE
	var amount := RISE_PER_DAB * strength
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var distance := Vector2(x, z).distance_to(at) / reach
			if distance >= 1.0:
				continue
			var weight := 0.5 + 0.5 * cos(PI * distance)
			var i := data.index(x, z)
			match _stroke_tool:
				Tool.RAISE:
					heights[i] += amount * weight
				Tool.LOWER:
					heights[i] -= amount * weight
				Tool.NOISE:
					heights[i] += _noise.get_noise_2d(x, z) * amount * 2.0 * weight
				Tool.FLATTEN:
					heights[i] = lerpf(heights[i], _flatten_height, strength * weight * 0.5)
				Tool.SMOOTH:
					var total := 0.0
					for dz in range(-1, 2):
						for dx in range(-1, 2):
							total += source[data.index(clampi(x + dx, 0, last.x), clampi(z + dz, 0, last.y))]
					heights[i] = lerpf(heights[i], total / 9.0, strength * weight)
	data.heights = heights
	_terrain.commit_heights(rect)


func _replace(terrain: Terrain, action: String, heights: PackedFloat32Array, tiles: PackedByteArray) -> void:
	var undo := _plugin.get_undo_redo()
	undo.create_action(action, UndoRedo.MERGE_DISABLE, terrain)
	undo.add_do_method(terrain, &"set_arrays", heights, tiles)
	undo.add_undo_method(terrain, &"set_arrays", terrain.data.heights.duplicate(), terrain.data.tiles.duplicate())
	undo.commit_action()


# --- Brush ring ----------------------------------------------------------------

func _update_brush() -> void:
	var root := EditorInterface.get_edited_scene_root()
	var show := tool != Tool.NONE and _cursor != Vector3.INF and root is Node3D and find_terrain() != null
	if not show:
		if is_instance_valid(_brush):
			_brush.visible = false
		return
	if not is_instance_valid(_brush) or _brush.get_parent() != root:
		cleanup()
		_brush = MeshInstance3D.new()
		_brush.name = BRUSH_NAME
		var ring := TorusMesh.new()
		ring.inner_radius = 0.95
		ring.outer_radius = 1.0
		ring.rings = 64
		ring.ring_segments = 4
		_brush.mesh = ring
		_brush.material_override = _brush_material
		_brush.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(_brush)  # not owned by the scene, so never saved
	_brush.visible = true
	_brush.global_position = Vector3(_cursor.x, 0.05, _cursor.z)  # the shader puts it on the terrain
	_brush.scale = Vector3(radius, 0.05, radius)
	_brush_material.set_shader_parameter(&"color", Color(TOOL_COLORS[tool], 0.9))


## Forwarded events are in the view's control space; the camera may render at half size.
static func _view_point(camera: Camera3D, point: Vector2) -> Vector2:
	var container := camera.get_viewport().get_parent() as SubViewportContainer
	return point / float(container.stretch_shrink) if container != null else point
