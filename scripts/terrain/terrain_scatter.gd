@tool
class_name TerrainScatter
extends Node3D

## Strews a Terrain's tiles with their ScatterItems: one MultiMesh per item per CHUNK meters
## square. Placement is seeded by chunk and item, so it is the same every time; each candidate
## spot is kept with the probability that its tile shows there, so scatter thins out where
## tiles blend. GraphicsSettings.scatter_quality scales the density and drops items marked for
## higher qualities. Chunks are computed on worker threads from a copy of the terrain data and
## turned into nodes as they finish. Created by the Terrain; never saved.

const CHUNK := 32.0  ## meters
const FOLIAGE_SHADER := preload("res://shaders/foliage_billboard.gdshader")

var terrain: Terrain

var _chunks: Dictionary[Vector2i, Array] = {}  ## chunk -> its MultiMeshInstance3D nodes
var _dirty: Dictionary[Vector2i, bool] = {}
var _versions: Dictionary[Vector2i, int] = {}  ## newest request per chunk; older results are dropped
var _tasks: Dictionary[int, Array] = {}  ## task id -> [chunk, version, result]
var _flush_queued := false
var _quad: QuadMesh
var _materials: Dictionary[Texture2D, ShaderMaterial] = {}


func _init() -> void:
	name = "Scatter"
	_quad = QuadMesh.new()
	_quad.center_offset = Vector3(0.0, 0.5, 0.0)  # stands on its bottom edge
	set_process(false)


func _exit_tree() -> void:
	for id in _tasks:
		WorkerThreadPool.wait_for_task_completion(id)
	_tasks.clear()


## Regenerates everything, e.g. after the tileset or the graphics quality changed.
func rebuild_all() -> void:
	if terrain == null or terrain.data == null or not terrain.data.is_valid():
		return
	var chunks := _chunk_count()
	for z in chunks.y:
		for x in chunks.x:
			_dirty[Vector2i(x, z)] = true
	for chunk in _chunks.keys():
		if chunk.x >= chunks.x or chunk.y >= chunks.y:
			_clear(chunk)
	_queue_flush()


## Regenerates the chunks over a vertex rect after the terrain there changed.
func mark(rect: Rect2i) -> void:
	if terrain == null or terrain.data == null:
		return
	var cell := terrain.data.cell_size
	var first := Vector2i((Vector2(rect.position - Vector2i.ONE) * cell / CHUNK).floor())
	var last := Vector2i((Vector2(rect.end + Vector2i.ONE) * cell / CHUNK).floor())
	var chunks := _chunk_count()
	for z in range(maxi(first.y, 0), mini(last.y, chunks.y - 1) + 1):
		for x in range(maxi(first.x, 0), mini(last.x, chunks.x - 1) + 1):
			_dirty[Vector2i(x, z)] = true
	_queue_flush()


## True while chunks are still being computed.
func is_busy() -> bool:
	return not _tasks.is_empty() or not _dirty.is_empty()


func _queue_flush() -> void:
	if not _flush_queued and is_inside_tree():
		_flush_queued = true
		_flush.call_deferred()


## Starts a worker task per dirty chunk, on a snapshot of the terrain taken now.
func _flush() -> void:
	_flush_queued = false
	if terrain == null or terrain.data == null or not terrain.data.is_valid():
		_dirty.clear()
		return
	var settings := GraphicsSettings.get_current()
	var enabled := terrain.tileset != null and settings.scatter_density() > 0.0 \
			and not (Engine.is_editor_hint() and not terrain.scatter_in_editor)
	var snapshot := {
		"heights": terrain.data.heights,
		"tiles": terrain.data.tiles,
		"size": terrain.data.size,
		"cell": terrain.data.cell_size,
		"corner": Vector2(terrain.global_position.x, terrain.global_position.z) - terrain.data.extent() * 0.5,
		"base": terrain.global_position.y,
		"density": settings.scatter_density(),
		"quality": settings.scatter_quality,
		"items": _items(),
	}
	for chunk in _dirty:
		_versions[chunk] = _versions.get(chunk, 0) + 1
		if not enabled:
			_clear(chunk)
			continue
		var job := [chunk, _versions[chunk], null]
		var id := WorkerThreadPool.add_task(_compute.bind(job, snapshot), false, "Terrain scatter")
		_tasks[id] = job
	_dirty.clear()
	set_process(not _tasks.is_empty())


## Turns finished chunks into nodes.
func _process(_frame_time: float) -> void:
	for id in _tasks.keys():
		if not WorkerThreadPool.is_task_completed(id):
			continue
		WorkerThreadPool.wait_for_task_completion(id)
		var job: Array = _tasks[id]
		_tasks.erase(id)
		var chunk: Vector2i = job[0]
		if job[1] == _versions.get(chunk, 0):
			_place(chunk, job[2])
	set_process(not _tasks.is_empty())


## [tile index, item, item index] for every scatter item of the tileset.
func _items() -> Array:
	var items := []
	for tile_index in terrain.tileset.tiles.size() if terrain.tileset != null else 0:
		var tile := terrain.tileset.tiles[tile_index]
		if tile == null:
			continue
		for item_index in tile.scatter.size():
			var item := tile.scatter[item_index]
			if item != null and (item.mesh != null or item.billboard != null):
				items.append([tile_index, item, item_index])
	return items


## Worker thread: the instance buffers of one chunk, from the snapshot only (no nodes).
static func _compute(job: Array, snapshot: Dictionary) -> void:
	var chunk: Vector2i = job[0]
	var heights: PackedFloat32Array = snapshot.heights
	var tiles: PackedByteArray = snapshot.tiles
	var size: Vector2i = snapshot.size
	var cell: float = snapshot.cell
	var corner: Vector2 = snapshot.corner
	var base: float = snapshot.base
	var extent := Vector2(size) * cell
	var low := Vector2(chunk) * CHUNK
	var high := (low + Vector2(CHUNK, CHUNK)).min(extent)
	var row := size.x + 1
	var results := []
	for entry: Array in snapshot.items:
		var tile_index: int = entry[0]
		var item: ScatterItem = entry[1]
		if item.min_quality > snapshot.quality:
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([chunk.x, chunk.y, tile_index, entry[2]])
		var wanted: float = item.density * snapshot.density * (high.x - low.x) * (high.y - low.y)
		var count := int(wanted) + (1 if rng.randf() < fmod(wanted, 1.0) else 0)
		var buffer := PackedFloat32Array()
		for i in count:
			var local := Vector2(rng.randf_range(low.x, high.x), rng.randf_range(low.y, high.y))
			var keep := rng.randf()
			var scale_factor := rng.randf_range(item.scale_range.x, item.scale_range.y)
			var yaw := rng.randf() * TAU
			var shade := 1.0 - rng.randf() * item.color_variation
			var hue := (rng.randf() - 0.5) * item.color_variation * 0.3
			# The cell and the weights of its corners
			var at := (local / cell).clamp(Vector2.ZERO, Vector2(size) - Vector2(0.0001, 0.0001))
			var ix := int(at.x)
			var iz := int(at.y)
			var fx := at.x - ix
			var fz := at.y - iz
			var i00 := iz * row + ix
			var weight := 0.0
			if tiles[i00] == tile_index:
				weight += (1.0 - fx) * (1.0 - fz)
			if tiles[i00 + 1] == tile_index:
				weight += fx * (1.0 - fz)
			if tiles[i00 + row] == tile_index:
				weight += (1.0 - fx) * fz
			if tiles[i00 + row + 1] == tile_index:
				weight += fx * fz
			if keep >= weight:
				continue
			# Height on the drawn triangle (split along the 00-11 diagonal, like Terrain)
			var h00 := heights[i00]
			var h10 := heights[i00 + 1]
			var h01 := heights[i00 + row]
			var h11 := heights[i00 + row + 1]
			var height := h00 + fx * (h10 - h00) + fz * (h11 - h10) if fx >= fz else h00 + fz * (h01 - h00) + fx * (h11 - h01)
			var orientation: Basis
			if item.billboard != null:
				orientation = Basis.from_scale(Vector3(item.billboard_size.x, item.billboard_size.y, item.billboard_size.x) * scale_factor)
			else:
				var normal := Vector3((h00 + h01 - h10 - h11) * 0.5, 2.0 * cell, (h00 + h10 - h01 - h11) * 0.5).normalized()
				var up := Vector3.UP.lerp(normal, item.align_to_ground).normalized()
				var tilt := Basis(Quaternion(Vector3.UP, up)) if not up.is_equal_approx(Vector3.UP) else Basis.IDENTITY
				orientation = tilt * Basis(Vector3.UP, yaw).scaled(Vector3.ONE * scale_factor)
			var origin := Vector3(corner.x + local.x, base + height - item.sink * scale_factor, corner.y + local.y)
			buffer.append_array([orientation.x.x, orientation.y.x, orientation.z.x, origin.x, orientation.x.y, orientation.y.y, orientation.z.y, origin.y,
					orientation.x.z, orientation.y.z, orientation.z.z, origin.z, shade + hue, shade, shade - hue, 1.0])
		if not buffer.is_empty():
			results.append([item, buffer])
	job[2] = results


func _place(chunk: Vector2i, results: Array) -> void:
	_clear(chunk)
	var nodes: Array[MultiMeshInstance3D] = []
	for result: Array in results:
		var item: ScatterItem = result[0]
		var buffer: PackedFloat32Array = result[1]
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = item.mesh if item.billboard == null else _quad
		multimesh.instance_count = int(buffer.size() / 16.0)
		multimesh.buffer = buffer
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = multimesh
		instance.top_level = true  # instances are placed in world space
		if item.billboard != null:
			instance.material_override = _foliage_material(item.billboard)
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if item.cast_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.visibility_range_end = item.max_distance
		instance.visibility_range_end_margin = 6.0
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(instance)
		nodes.append(instance)
	_chunks[chunk] = nodes


func _chunk_count() -> Vector2i:
	return Vector2i((terrain.data.extent() / CHUNK).ceil())


func _clear(chunk: Vector2i) -> void:
	for node: Node in _chunks.get(chunk, []):
		remove_child(node)
		node.queue_free()
	_chunks.erase(chunk)


func _foliage_material(texture: Texture2D) -> ShaderMaterial:
	if not _materials.has(texture):
		var material := ShaderMaterial.new()
		material.shader = FOLIAGE_SHADER
		material.set_shader_parameter(&"albedo", texture)
		_materials[texture] = material
	return _materials[texture]
