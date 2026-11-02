@tool
class_name Terrain
extends Node3D

## Height-displaced ground painted with a TerrainTileset.
##
## Gameplay stays 2D on the plane y = 0: units, props and the navigation mesh live there,
## and only their visuals are lifted, by Terrain.lift() / ground(). Spells or flying units
## that rise keep that rise in their own y, on top of the ground. The heights also go to the
## global shader uniforms in shaders/terrain_height.gdshaderinc, so ground-hugging materials
## (selection rings, targeting indicators, decals) follow the terrain on the GPU.
##
## Cells painted with an unwalkable tile, or steeper than max_walkable_slope, are carved out
## of the navigation mesh (NavigationObstacle3D children, rebuilt when the terrain changes).
## Tiles' ScatterItems are strewn over them by a TerrainScatter child, as dense as
## GraphicsSettings allows.
##
## Keep the node unrotated and unscaled; moving it is fine.

signal heights_changed(rect: Rect2i)  ## vertex rect that changed
signal tiles_changed(rect: Rect2i)

const SHADER := preload("res://shaders/terrain.gdshader")
const NAVIGATION_GROUP := &"navigation_geometry"
const LAYER_WORLD := 1
const STROKE_SCATTER_INTERVAL := 0.25  ## seconds between scatter refreshes while a brush strokes

static var current: Terrain  ## the running map's terrain; null on maps without one

@export var data: TerrainData:
	set(value):
		data = value
		if is_inside_tree():
			rebuild()
@export var tileset: TerrainTileset:
	set(value):
		if tileset != null and tileset.changed.is_connected(_on_tileset_changed):
			tileset.changed.disconnect(_on_tileset_changed)
		tileset = value
		if tileset != null:
			tileset.changed.connect(_on_tileset_changed)
		if is_inside_tree():
			_update_tiles_textures()
## Cells steeper than this (degrees) are left out of the navigation mesh.
@export_range(5.0, 90.0, 1.0) var max_walkable_slope := 50.0:
	set(value):
		max_walkable_slope = value
		_update_blocked(Rect2i(), true)
		_queue_blockers()
## Show the tiles' scatter in the editor too.
@export var scatter_in_editor := true:
	set(value):
		scatter_in_editor = value
		if _scatter != null:
			_scatter.rebuild_all()

var _mesh: ArrayMesh
var _mesh_instance: MeshInstance3D
var _material := ShaderMaterial.new()
var _height_image: Image
var _height_texture: ImageTexture
var _tile_image: Image
var _tile_texture: ImageTexture
var _body: StaticBody3D
var _shape: CollisionShape3D
var _height_range := Vector2.ZERO
var _blockers: Node3D
var _blockers_queued := false
var _scatter: TerrainScatter
var _blocked := PackedByteArray()  ## per cell: 1 when units can't walk it (blocked_cells)
var _walkable := PackedByteArray()  ## per tile id: 1 when walkable, from the tileset
## While the editor brush strokes (begin_stroke): what changed, for the work held back.
var _stroking := false
var _stroke_rect := Rect2i()
var _scatter_rect := Rect2i()
var _scatter_timer_running := false


func _enter_tree() -> void:
	current = self
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "Mesh"
		_mesh_instance.material_override = _material
		add_child(_mesh_instance)
		_body = StaticBody3D.new()
		_body.name = "Ground"
		_body.collision_layer = LAYER_WORLD
		_shape = CollisionShape3D.new()
		_shape.shape = BoxShape3D.new()
		_body.add_child(_shape)
		add_child(_body)
		_blockers = Node3D.new()
		_blockers.name = "Blockers"
		add_child(_blockers)
		_scatter = TerrainScatter.new()
		_scatter.terrain = self
		add_child(_scatter)
	var settings := GraphicsSettings.get_current()
	if not settings.changed.is_connected(_scatter.rebuild_all):
		settings.changed.connect(_scatter.rebuild_all)
	_material.shader = SHADER
	_material.set_shader_parameter(&"edge_noise", _edge_noise())
	add_to_group(NAVIGATION_GROUP)
	rebuild()
	set_notify_transform(true)


func _exit_tree() -> void:
	var settings := GraphicsSettings.get_current()
	if settings.changed.is_connected(_scatter.rebuild_all):
		settings.changed.disconnect(_scatter.rebuild_all)
	if current == self:
		current = null
		RenderingServer.global_shader_parameter_set(&"terrain_grid", Vector4.ZERO)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		_publish()


## Visual ground height under a gameplay point; 0 on maps without a terrain.
static func ground(x: float, z: float) -> float:
	return current.height_at(x, z) if current != null else 0.0


## Where a gameplay position is drawn: its y (any rise above the ground) on top of the terrain.
static func lift(point: Vector3) -> Vector3:
	return Vector3(point.x, point.y + ground(point.x, point.z), point.z)


## Points every `step` meters along the segment from a to b, each lifted onto the ground, for
## lines drawn over the terrain (order paths, targeting lines).
static func ground_path(a: Vector3, b: Vector3, step := 1.0) -> PackedVector3Array:
	var count := maxi(1, ceili(Vector2(b.x - a.x, b.z - a.z).length() / step))
	var points := PackedVector3Array()
	for i in count + 1:
		points.append(lift(a.lerp(b, float(i) / count)))
	return points


## The terrain point under a screen ray (the gameplay point is that with y = 0). Falls back to
## the plane y = 0 without a terrain. Returns Vector3.INF when the ray misses.
static func trace(from: Vector3, direction: Vector3) -> Vector3:
	if current != null:
		return current.raycast(from, direction)
	var hit: Variant = Plane.PLANE_XZ.intersects_ray(from, direction)
	return hit if hit != null else Vector3.INF


## Height of the drawn surface at world x, z: the same triangles the GPU draws.
func height_at(x: float, z: float) -> float:
	if data == null or not data.is_valid():
		return 0.0
	var cell := _vertex_coords(x, z)
	var last := Vector2(data.size) - Vector2(0.0001, 0.0001)
	cell = cell.clamp(Vector2.ZERO, last)
	var i := int(cell.x)
	var j := int(cell.y)
	var fx := cell.x - i
	var fz := cell.y - j
	var row := data.size.x + 1
	var h00 := data.heights[j * row + i]
	var h10 := data.heights[j * row + i + 1]
	var h01 := data.heights[(j + 1) * row + i]
	var h11 := data.heights[(j + 1) * row + i + 1]
	# Each quad is split along its (0,0)-(1,1) diagonal, like _build_mesh
	if fx >= fz:
		return h00 + fx * (h10 - h00) + fz * (h11 - h10)
	return h00 + fz * (h01 - h00) + fx * (h11 - h01)


## First hit of a ray with the drawn surface, Vector3.INF if none: marches the ray in half-cell
## steps through the terrain's height range, then bisects the crossing.
func raycast(from: Vector3, direction: Vector3, max_distance := 2000.0) -> Vector3:
	if data == null or not data.is_valid():
		var hit: Variant = Plane(Vector3.UP, global_position.y).intersects_ray(from, direction)
		return hit if hit != null else Vector3.INF
	direction = direction.normalized()
	var top := global_position.y + _height_range.y + 0.01
	var bottom := global_position.y + _height_range.x - 0.01
	var start := 0.0
	var end := max_distance
	if absf(direction.y) > 0.00001:
		var t_top := (top - from.y) / direction.y
		var t_bottom := (bottom - from.y) / direction.y
		start = maxf(minf(t_top, t_bottom), 0.0)
		end = minf(maxf(t_top, t_bottom), max_distance)
	elif from.y > top or from.y < bottom:
		return Vector3.INF
	var step := data.cell_size * 0.5
	var previous := start
	var t := start
	while t <= end + step:
		var point := from + direction * minf(t, end)
		if point.y <= global_position.y + height_at(point.x, point.z):
			var low := previous
			var high := minf(t, end)
			for _i in 12:
				var mid := (low + high) * 0.5
				var probe := from + direction * mid
				if probe.y <= global_position.y + height_at(probe.x, probe.z):
					high = mid
				else:
					low = mid
			var hit := from + direction * high
			return Vector3(hit.x, global_position.y + height_at(hit.x, hit.z), hit.z)
		previous = t
		t += step
	return Vector3.INF


## Fractional vertex coordinates of world x, z.
func vertex_coords(world: Vector3) -> Vector2:
	return _vertex_coords(world.x, world.z)


## World position of vertex (x, z) on the drawn surface.
func vertex_position(x: int, z: int) -> Vector3:
	var origin := _origin()
	return Vector3(origin.x + x * data.cell_size, global_position.y + data.heights[data.index(x, z)], origin.y + z * data.cell_size)


## How much of `tile` shows at world x, z, 0..1: the weights of the cell corners painted with it.
func tile_weight(x: float, z: float, tile: int) -> float:
	var cell := _vertex_coords(x, z).clamp(Vector2.ZERO, Vector2(data.size) - Vector2(0.0001, 0.0001))
	var i := int(cell.x)
	var j := int(cell.y)
	var fx := cell.x - i
	var fz := cell.y - j
	var row := data.size.x + 1
	var at := j * row + i
	var weight := 0.0
	if data.tiles[at] == tile:
		weight += (1.0 - fx) * (1.0 - fz)
	if data.tiles[at + 1] == tile:
		weight += fx * (1.0 - fz)
	if data.tiles[at + row] == tile:
		weight += (1.0 - fx) * fz
	if data.tiles[at + row + 1] == tile:
		weight += fx * fz
	return weight


## Surface normal at world x, z, from the heights around it.
func normal_at(x: float, z: float) -> Vector3:
	var step := data.cell_size
	var dx := height_at(x + step, z) - height_at(x - step, z)
	var dz := height_at(x, z + step) - height_at(x, z - step)
	return Vector3(-dx, 2.0 * step, -dz).normalized()


func tile_at(x: float, z: float) -> int:
	var cell := _vertex_coords(x, z).round()
	var at := Vector2i(cell.clamp(Vector2.ZERO, Vector2(data.size)))
	return data.tiles[data.index(at.x, at.y)]


## Pushes edited heights in `rect` (vertex coordinates) to the GPU and tells listeners.
func commit_heights(rect: Rect2i) -> void:
	rect = rect.intersection(Rect2i(Vector2i.ZERO, data.vertices()))
	var heights := data.heights
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			_height_image.set_pixel(x, z, Color(heights[data.index(x, z)], 0.0, 0.0))
	_height_texture.update(_height_image.duplicate())  # its own: the render thread reads it later
	if _stroking:
		_grow_bounds(rect)
	else:
		_update_bounds()
	_changed(rect)
	if Engine.is_editor_hint():
		_settle_props(rect)
	heights_changed.emit(rect)


## Pushes edited tile ids in `rect` (vertex coordinates) to the GPU and tells listeners.
func commit_tiles(rect: Rect2i) -> void:
	rect = rect.intersection(Rect2i(Vector2i.ZERO, data.vertices()))
	var tiles := data.tiles
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			_tile_image.set_pixel(x, z, Color(tiles[data.index(x, z)] / 255.0, 0.0, 0.0))
	_tile_texture.update(_tile_image.duplicate())  # its own: the render thread reads it later
	_changed(rect)
	tiles_changed.emit(rect)


## The Map Editor's brush starts a stroke: until end_stroke(), edits only refresh what is
## under the brush. The navigation blockers wait for the end; the scatter catches up a few
## times a second. Keeps painting from rescanning the whole map on every dab.
func begin_stroke() -> void:
	_stroking = true
	_stroke_rect = Rect2i()


func end_stroke() -> void:
	if not _stroking:
		return
	_stroking = false
	if not _stroke_rect.has_area() or data == null:
		return
	_update_bounds()
	_flush_stroke_scatter()
	_queue_blockers()


## Bookkeeping for an edit of the vertices in `rect`: blocked cells, blockers and scatter.
func _changed(rect: Rect2i) -> void:
	_update_blocked(rect)
	if not _stroking:
		_queue_blockers()
		_scatter.mark(rect)
		return
	_stroke_rect = rect if not _stroke_rect.has_area() else _stroke_rect.merge(rect)
	_scatter_rect = rect if not _scatter_rect.has_area() else _scatter_rect.merge(rect)
	if not _scatter_timer_running and is_inside_tree():
		_scatter_timer_running = true
		get_tree().create_timer(STROKE_SCATTER_INTERVAL).timeout.connect(_flush_stroke_scatter)


func _flush_stroke_scatter() -> void:
	_scatter_timer_running = false
	if _scatter_rect.has_area() and is_instance_valid(_scatter):
		_scatter.mark(_scatter_rect)
	_scatter_rect = Rect2i()


## Replaces all heights and tiles at once, e.g. for undo or a generated landscape.
func set_arrays(heights: PackedFloat32Array, tiles: PackedByteArray) -> void:
	data.heights = heights.duplicate()
	data.tiles = tiles.duplicate()
	var all := Rect2i(Vector2i.ZERO, data.vertices())
	commit_heights(all)
	commit_tiles(all)


## Cells units can't walk on: painted unwalkable (two or more corners), too steep, or marked
## in data.blockers.
## Kept up to date per edit; the whole map is only computed on a rebuild.
func blocked_cells() -> PackedByteArray:
	if _blocked.size() != data.size.x * data.size.y:
		_update_blocked(Rect2i(Vector2i.ZERO, data.vertices()), true)
	return _blocked


## Recomputes the blocked cells touching the vertices in `rect` (everything when `full`).
func _update_blocked(rect: Rect2i, full := false) -> void:
	if data == null or not data.is_valid():
		return
	if full or _blocked.size() != data.size.x * data.size.y:
		_blocked.resize(data.size.x * data.size.y)
		_walkable.resize(256)
		for tile in 256:
			_walkable[tile] = 1 if tileset == null or tileset.is_walkable(tile) else 0
		rect = Rect2i(Vector2i.ZERO, data.vertices())
	# A cell's corners are vertices (x, z) to (x + 1, z + 1)
	var cells := Rect2i(rect.position - Vector2i.ONE, rect.size + Vector2i.ONE).intersection(Rect2i(Vector2i.ZERO, data.size))
	var heights := data.heights
	var tiles := data.tiles
	var walkable := _walkable
	var blockers := data.blockers
	var has_blockers := blockers.size() == data.size.x * data.size.y
	var max_rise := tan(deg_to_rad(max_walkable_slope)) * data.cell_size
	var diagonal := max_rise * sqrt(2.0)
	var row := data.size.x + 1
	for z in range(cells.position.y, cells.end.y):
		for x in range(cells.position.x, cells.end.x):
			var i := z * row + x
			var unwalkable := 4 - walkable[tiles[i]] - walkable[tiles[i + 1]] - walkable[tiles[i + row]] - walkable[tiles[i + row + 1]]
			var h00 := heights[i]
			var h10 := heights[i + 1]
			var h01 := heights[i + row]
			var h11 := heights[i + row + 1]
			var steep := absf(h00 - h10) > max_rise or absf(h01 - h11) > max_rise or absf(h00 - h01) > max_rise \
					or absf(h10 - h11) > max_rise or absf(h00 - h11) > diagonal
			_blocked[z * data.size.x + x] = 1 if unwalkable >= 2 or steep or (has_blockers and blockers[z * data.size.x + x] == 1) else 0


## Widens the height range (for culling) by the vertices in `rect`; a full rescan
## (_update_bounds) happens when the stroke ends.
func _grow_bounds(rect: Rect2i) -> void:
	var heights := data.heights
	var low := _height_range.x
	var high := _height_range.y
	for z in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var h := heights[data.index(x, z)]
			low = minf(low, h)
			high = maxf(high, h)
	if low < _height_range.x or high > _height_range.y:
		_height_range = Vector2(low, high)
		_apply_bounds()


## Rebuilds everything from `data` and `tileset`, e.g. after resizing the data.
func rebuild() -> void:
	if _mesh_instance == null:
		return
	if data == null or not data.is_valid():
		_mesh_instance.mesh = null
		return
	_build_mesh()
	var vertices := data.vertices()
	_height_image = Image.create_from_data(vertices.x, vertices.y, false, Image.FORMAT_RF, data.heights.to_byte_array())
	_tile_image = Image.create_from_data(vertices.x, vertices.y, false, Image.FORMAT_R8, data.tiles)
	_height_texture = ImageTexture.create_from_image(_height_image)
	_tile_texture = ImageTexture.create_from_image(_tile_image)
	_material.set_shader_parameter(&"heightmap", _height_texture)
	_material.set_shader_parameter(&"tilemap", _tile_texture)
	_material.set_shader_parameter(&"tintmap", _tint_texture())
	_material.set_shader_parameter(&"cell_size", data.cell_size)
	_update_tiles_textures()
	_update_bounds()
	var extent := data.extent()
	(_shape.shape as BoxShape3D).size = Vector3(extent.x, 1.0, extent.y)
	_shape.position = Vector3(0.0, -0.5, 0.0)
	_publish()
	_update_blocked(Rect2i(), true)
	_update_blockers()
	_scatter.rebuild_all()
	heights_changed.emit(Rect2i(Vector2i.ZERO, vertices))
	tiles_changed.emit(Rect2i(Vector2i.ZERO, vertices))


func _build_mesh() -> void:
	var vertices := data.vertices()
	var origin := -data.extent() * 0.5
	var points := PackedVector3Array()
	var uvs := PackedVector2Array()
	points.resize(vertices.x * vertices.y)
	uvs.resize(points.size())
	for z in vertices.y:
		for x in vertices.x:
			var i := data.index(x, z)
			points[i] = Vector3(origin.x + x * data.cell_size, 0.0, origin.y + z * data.cell_size)
			uvs[i] = Vector2(float(x) / data.size.x, float(z) / data.size.y)
	var indices := PackedInt32Array()
	indices.resize(data.size.x * data.size.y * 6)
	var n := 0
	for z in data.size.y:
		for x in data.size.x:
			var a := data.index(x, z)
			var b := a + 1
			var c := a + vertices.x
			var d := c + 1
			# Split along a-d; clockwise from above, Godot's front face
			indices[n] = a
			indices[n + 1] = b
			indices[n + 2] = d
			indices[n + 3] = a
			indices[n + 4] = d
			indices[n + 5] = c
			n += 6
	var normals := PackedVector3Array()
	normals.resize(points.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = points
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	_mesh = ArrayMesh.new()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance.mesh = _mesh


## data.tint as a texture, one texel per vertex; plain white without it.
func _tint_texture() -> ImageTexture:
	var vertices := data.vertices()
	if data.tint.size() == vertices.x * vertices.y * 3:
		return ImageTexture.create_from_image(Image.create_from_data(vertices.x, vertices.y, false, Image.FORMAT_RGB8, data.tint))
	var white := Image.create(1, 1, false, Image.FORMAT_RGB8)
	white.fill(Color.WHITE)
	return ImageTexture.create_from_image(white)


static func _edge_noise() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.frequency = 0.02
	noise.fractal_octaves = 3
	var texture := NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	texture.generate_mipmaps = true
	texture.noise = noise
	return texture


func _update_tiles_textures() -> void:
	if tileset == null:
		tileset = TerrainTileset.new()
	var arrays := tileset.build_arrays()
	_material.set_shader_parameter(&"albedo_array", arrays[0])
	_material.set_shader_parameter(&"height_array", arrays[1])
	_material.set_shader_parameter(&"tile_meters", tileset.tile_meters())


func _update_bounds() -> void:
	var low := INF
	var high := -INF
	for h in data.heights:
		low = minf(low, h)
		high = maxf(high, h)
	_height_range = Vector2(low, high)
	_apply_bounds()


func _apply_bounds() -> void:
	var low := _height_range.x
	var high := _height_range.y
	if _mesh != null:
		var extent := data.extent()
		_mesh.custom_aabb = AABB(Vector3(-extent.x * 0.5, low, -extent.y * 0.5), Vector3(extent.x, maxf(high - low, 0.01), extent.y))


## Stands the props over the reshaped area back on the ground (editor; at runtime props
## settle themselves when the map loads).
func _settle_props(rect: Rect2i) -> void:
	var area := rect.grow(1)
	for node in get_tree().get_nodes_in_group(MapProp.GROUP):
		var prop := node as MapProp
		if prop != null and area.has_point(Vector2i(vertex_coords(prop.global_position).round())):
			prop.settle()


func _queue_blockers() -> void:
	if not _blockers_queued and is_inside_tree():
		_blockers_queued = true
		_update_blockers.call_deferred()


## Carves blocked cells out of the navigation mesh, merged into as few rectangles as it can.
func _update_blockers() -> void:
	_blockers_queued = false
	if _blockers == null or data == null or not data.is_valid():
		return
	for child in _blockers.get_children():
		_blockers.remove_child(child)
		child.queue_free()
	var blocked := blocked_cells()
	var claimed := PackedByteArray()
	claimed.resize(blocked.size())
	var width := data.size.x
	var origin := -data.extent() * 0.5
	for z in data.size.y:
		var x := 0
		while x < width:
			if blocked[z * width + x] == 0 or claimed[z * width + x] == 1:
				x += 1
				continue
			var end := x
			while end < width and blocked[z * width + end] == 1 and claimed[z * width + end] == 0:
				end += 1
			# Grow the run down while the next row is blocked across the same span
			var bottom := z + 1
			while bottom < data.size.y and _run_free(blocked, claimed, bottom, x, end):
				bottom += 1
			for zz in range(z, bottom):
				for xx in range(x, end):
					claimed[zz * width + xx] = 1
			var a := Vector3(origin.x + x * data.cell_size, 0.0, origin.y + z * data.cell_size)
			var b := Vector3(origin.x + end * data.cell_size, 0.0, origin.y + bottom * data.cell_size)
			var obstacle := NavigationObstacle3D.new()
			obstacle.avoidance_enabled = false
			obstacle.affect_navigation_mesh = true
			obstacle.carve_navigation_mesh = true
			obstacle.height = 4.0
			obstacle.vertices = PackedVector3Array([a, Vector3(b.x, 0.0, a.z), b, Vector3(a.x, 0.0, b.z)])
			_blockers.add_child(obstacle)
			x = end


func _run_free(blocked: PackedByteArray, claimed: PackedByteArray, z: int, from: int, to: int) -> bool:
	var width := data.size.x
	for x in range(from, to):
		if blocked[z * width + x] == 0 or claimed[z * width + x] == 1:
			return false
	return true


func _publish() -> void:
	if data == null or not data.is_valid() or not is_inside_tree():
		return
	var origin := _origin()
	RenderingServer.global_shader_parameter_set(&"terrain_heightmap", _height_texture)
	RenderingServer.global_shader_parameter_set(&"terrain_grid", Vector4(origin.x, origin.y, 1.0 / data.cell_size, 1.0))


func _origin() -> Vector2:
	return Vector2(global_position.x, global_position.z) - data.extent() * 0.5


func _vertex_coords(x: float, z: float) -> Vector2:
	return (Vector2(x, z) - _origin()) / data.cell_size


func _on_tileset_changed() -> void:
	if is_inside_tree():
		_update_tiles_textures()
		_update_blocked(Rect2i(), true)  # walkable tiles may have changed
		_queue_blockers()
		_scatter.rebuild_all()
