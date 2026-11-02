class_name FogOfWar
extends Node3D

## noh's fog of war: every team sees only what its units see.
##
## Server side (CGameServer::UpdateVisibility): every update_time each team's visibility
## map is rebuilt from its units' sight ranges, cut short by an occlusion map
## (COcclusionMap: terrain heights, raised by the props that block sight). A cell blocks
## the sight of a unit whose eyes, occlusion_height above its ground, are below the cell's
## top, so low ground can't see onto high ground or past walls. Every tick (Simulation) each
## row's `sighted` bits (VIS_SIGHTED) are set from those maps; a unit that attacked a team
## shows to that team for aggression_sight_time even from the fog.
##
## Client side (CGameClient::DrawFogofWar, vid_gl2/c_fogofwar.cpp): the player's team map
## becomes a texture, cross-faded from the previous update to the latest, and a full-screen
## pass darkens whatever the team doesn't see. Units the player can't see aren't drawn.
##
## The casting runs in the native core (native/src/core/sight.zig, through the UnitRegistry):
## noh rasterized sight with recursive shadowcasting (CRasterBuffer::CalcVisibilty2); there each
## sight radius gets a table of its cells, ring by ring outward, each pointing at the cell before
## it on the line from the center: a cell is seen when that one is seen and doesn't block. Same
## result (blockers are seen, what's behind them isn't), one flat loop per unit, every unit of
## every team in well under a millisecond. This node lays out the grid, builds the occlusion
## map, and draws the player's team map.

const NOH_UNITS := RTSCamera.NOH_UNITS_PER_METER
const SHADER := preload("res://shaders/fog_of_war.gdshader")
const ALL_TEAMS := -1  ## sighted bits with fog of war off: everyone sees everything
const MAX_SIGHT_RANGE := 50.0  ## sight is cut short past this (noh RASTER_BUFFER_SPAN)
const SEEN := 255
const MONITOR := &"RTS/Fog of war (ms)"  ## FrameMonitor: the last tick's sight work
const UNIT_SIZE_CELLS := 1  ## noh widens a revealed unit's footprint by a cell

static var current: FogOfWar  ## the running map's fog; null on maps without one

@export var registry: UnitRegistry
## Off: everyone sees everything (noh cg_fogofwar; full vision).
@export var enabled := true:
	set(value):
		enabled = value
		_published = false  # redraw at once
## Size of a visibility cell; the map's terrain cells by default (noh: two tiles).
@export var cell_size := 1.0
@export var update_time := 0.4  ## g_fogofwarUpdateTime
@export var occlusion_height := 64.0 / NOH_UNITS  ## g_occlusionHeight: eye height above the ground
@export var aggression_sight_time := 3.0  ## g_unitAggressionSightTime
@export_range(0.0, 1.0) var darkness := 0.5  ## cg_fogofwarDarkness
## Map area without a Terrain to take it from.
@export var bounds := Rect2(-80.0, -80.0, 160.0, 160.0)


## The cells within one sight radius, ring by ring outward: each one's offset in the padded
## grid and the index of the cell before it on the line from the center.
class Rays:
	var offsets := PackedInt32Array()
	var parents := PackedInt32Array()
	var open := PackedByteArray()  ## scratch: seen and not blocking, per cell


var _usec := 0  ## the last tick's work, for the monitor
var _origin := Vector2.ZERO  ## world XZ of cell (0, 0)
var _size := Vector2i.ZERO  ## cells covering the map
var _pad := 0  ## cells of margin around the map, so sight near the edge needs no clipping
var _width := 0  ## padded row length
var _heights := PackedFloat32Array()  ## per padded cell: the top of what is there (COcclusionMap)
var _ground := PackedFloat32Array()  ## per padded cell: the ground where eyes stand
var _player_map := PackedByteArray()  ## the player's team: SEEN cells, last finished update
var _rays: Dictionary[int, Rays] = {}  ## radius in cells -> its table (attackers' footprints)
var _timer := 0.0
var _published := false  ## a finished update is shown
var _occlusion_dirty := true
var _image: Image
var _textures: Array[ImageTexture] = []
var _newest := 0  ## index of the latest texture
var _blend := 1.0
var _quad: MeshInstance3D
var _material := ShaderMaterial.new()


func _ready() -> void:
	current = self
	registry.fog_of_war = self
	Simulation.join(self, Simulation.Order.SIGHT)  # sight flags are fresh before any unit thinks
	_layout()
	if Terrain.current != null:
		Terrain.current.heights_changed.connect(_on_terrain_changed)
	_create_quad()
	FrameMonitor.add(MONITOR, func() -> float: return _usec / 1000.0)


func _exit_tree() -> void:
	if current == self:
		current = null
	FrameMonitor.remove(MONITOR)


## Whether the player's team sees a point; true without fog of war.
static func player_sees(point: Vector3) -> bool:
	if current == null or not current.enabled:
		return true
	var map := current._player_map
	return not map.is_empty() and map[current._cell_index(point)] != 0


## The teams that see a unit (noh VIS_SIGHTED bits): its own, the teams whose maps cover its
## cell, and the teams it attacked a moment ago. Every tick the native core does this for all
## units at once (UnitRegistry.update_sight); this is for one unit, when it appears or hides.
func sight_bits(handle: int) -> int:
	return registry.sight_bits_of(handle, enabled, aggression_sight_time) if enabled else ALL_TEAMS


## Rebuilds the occlusion map, e.g. after props were added or moved.
func rebuild_occlusion() -> void:
	_occlusion_dirty = true


func _simulate(delta: float) -> void:
	var started := Time.get_ticks_usec()
	if _occlusion_dirty:
		_build_occlusion()
	_timer -= delta
	if _timer <= 0.0 or not _published:
		_timer = update_time
		if enabled:
			registry.update_fog(occlusion_height)
		_player_map = registry.sight_map(registry.player_team) if enabled else PackedByteArray()
		_upload()
		_published = true
	_update_sight_flags()
	_usec = Time.get_ticks_usec() - started


func _process(delta: float) -> void:
	_blend = minf(_blend + delta / update_time, 1.0)
	_material.set_shader_parameter(&"fog_blend", _blend)
	# noh multiplied in gamma space; the 3D scene here is linear
	_material.set_shader_parameter(&"shade", pow(1.0 - darkness, 2.2))
	_quad.visible = enabled


# --- Visibility maps (CGameServer::UpdateVisibility) ---------------------------

## The ray table of a sight radius, built on first use.
func _rays_for(radius: int) -> Rays:
	if _rays.has(radius):
		return _rays[radius]
	var rays := Rays.new()
	var index: Dictionary[Vector2i, int] = {}
	var limit := radius * radius + radius  # rounder than r², like noh's midpoint circles
	for ring in radius + 1:
		for cell in _ring(ring):
			if cell.length_squared() > limit:
				continue
			var parent := 0
			if ring > 0:
				# The previous step on the line from the center: one ring further in
				var shrink := (ring - 1.0) / ring
				parent = index[Vector2i(roundi(cell.x * shrink), roundi(cell.y * shrink))]
			index[cell] = rays.offsets.size()
			rays.offsets.append(cell.y * _width + cell.x)
			rays.parents.append(parent)
	rays.open.resize(rays.offsets.size())
	_rays[radius] = rays
	return rays


static func _ring(ring: int) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	if ring == 0:
		cells.append(Vector2i.ZERO)
		return cells
	for x in range(-ring, ring + 1):
		cells.append(Vector2i(x, -ring))
		cells.append(Vector2i(x, ring))
	for y in range(-ring + 1, ring):
		cells.append(Vector2i(-ring, y))
		cells.append(Vector2i(ring, y))
	return cells


## The player's team map to the GPU (CGameClient::DrawFogofWar): it cross-fades from the
## texture shown so far over the next update_time.
func _upload() -> void:
	var view := PackedByteArray()
	if enabled:
		view = _player_map.duplicate()
		view.resize(_heights.size())  # nothing seen yet when the core had no map to give
		_reveal_attackers(view)
	else:
		view.resize(_heights.size())
		view.fill(SEEN)
	_image.set_data(_width, _size.y + _pad * 2, false, Image.FORMAT_R8, view)
	_newest = 1 - _newest
	_textures[_newest].update(_image.duplicate())  # its own: the render thread reads it later, and _image changes
	_material.set_shader_parameter(&"fog_previous", _textures[1 - _newest])
	_material.set_shader_parameter(&"fog_current", _textures[_newest])
	_blend = 0.0 if _published else 1.0


## Enemies that attacked the player's team show the ground under them (noh draws their bounds).
func _reveal_attackers(view: PackedByteArray) -> void:
	var team := registry.player_team
	var since := registry.now() - aggression_sight_time
	for handle in registry.handles(-1):
		if registry.team_of(handle) == team or registry.last_aggression(handle, team) <= since:
			continue
		var radius := mini(floori(registry.radius_of(handle) / cell_size) + UNIT_SIZE_CELLS, _pad - 1)
		var rays := _rays_for(radius)
		var center := _cell_index(registry.position_of(handle))
		for offset in rays.offsets:
			view[center + offset] = SEEN


## noh's "update sight flags" pass, every frame from the latest maps: in the native core.
func _update_sight_flags() -> void:
	registry.update_sight(enabled, aggression_sight_time)


# --- Occlusion map (COcclusionMap) ---------------------------------------------

## Sizes the grids to the map: the Terrain's area, or `bounds` without one.
func _layout() -> void:
	var area := bounds
	var terrain := Terrain.current
	if terrain != null and terrain.data != null and terrain.data.is_valid():
		var extent := terrain.data.extent()
		area = Rect2(Vector2(terrain.global_position.x, terrain.global_position.z) - extent * 0.5, extent)
	_origin = area.position
	_size = Vector2i((area.size / cell_size).ceil())
	_pad = ceili(MAX_SIGHT_RANGE / cell_size) + 1
	_width = _size.x + _pad * 2
	var height := _size.y + _pad * 2
	_heights.resize(_width * height)
	_ground.resize(_width * height)
	_player_map = PackedByteArray()
	_rays.clear()
	_image = Image.create_empty(_width, height, false, Image.FORMAT_R8)
	_image.fill(Color.WHITE)  # noh starts both textures fully visible
	_textures = [ImageTexture.create_from_image(_image), ImageTexture.create_from_image(_image)]
	_material.set_shader_parameter(&"fog_rect", Vector4(_origin.x - _pad * cell_size, _origin.y - _pad * cell_size,
			_width * cell_size, height * cell_size))
	_material.set_shader_parameter(&"map_rect", Vector4(area.position.x, area.position.y, area.size.x, area.size.y))
	_material.set_shader_parameter(&"fog_previous", _textures[0])
	_material.set_shader_parameter(&"fog_current", _textures[1])
	_occlusion_dirty = true
	_published = false
	registry.set_sight_layout(_origin, _size, cell_size, _pad)


## The top of each cell: the highest terrain corner in it (InitTerrainHeight), raised to
## the top of any prop blocking sight there. Cells off the map block everything. Also the
## ground of each cell (its corners' average), where the eyes of a unit in it stand.
func _build_occlusion() -> void:
	_occlusion_dirty = false
	_heights.fill(INF)
	_ground.fill(0.0)
	var terrain := Terrain.current
	var data := terrain.data if terrain != null else null
	var has_terrain := data != null and data.is_valid()
	for z in _size.y:
		for x in _size.x:
			var cell := (z + _pad) * _width + x + _pad
			if has_terrain:
				var top_and_ground := _terrain_top(data, x, z)
				_heights[cell] = top_and_ground.x
				_ground[cell] = top_and_ground.y
			else:
				_heights[cell] = 0.0
	for node in get_tree().get_nodes_in_group(MapProp.GROUP):
		var prop := node as MapProp
		if prop != null and prop.blocks_movement and prop.blocks_vision:
			_occlude(prop.get_footprint(), prop.get_top())
	registry.set_sight_occlusion(_heights, _ground)


## The highest and the average height of the terrain corners in a cell.
func _terrain_top(data: TerrainData, x: int, z: int) -> Vector2:
	# Terrain vertices under the cell (the grids share their origin), in vertex coordinates
	var low := Vector2(x, z) * (cell_size / data.cell_size)
	var high := low + Vector2.ONE * (cell_size / data.cell_size)
	var from := Vector2i(low.floor()).clamp(Vector2i.ZERO, data.size)
	var to := Vector2i(high.ceil()).clamp(Vector2i.ZERO, data.size)
	var top := -INF
	var sum := 0.0
	var count := 0
	for vz in range(from.y, to.y + 1):
		for vx in range(from.x, to.x + 1):
			var height := data.heights[data.index(vx, vz)]
			top = maxf(top, height)
			sum += height
			count += 1
	return Vector2(top, sum / maxi(count, 1))


## Raises the cells a footprint touches to `top`. A cell counts as touched when its center
## is within half a cell of the outline, so thin walls still block whole cells.
func _occlude(footprint: PackedVector2Array, top: float) -> void:
	if footprint.size() < 3:
		return
	var grown := Geometry2D.offset_polygon(footprint, cell_size * 0.5, Geometry2D.JOIN_MITER)
	var outline: PackedVector2Array = grown[0] if not grown.is_empty() else footprint
	var area := Rect2(outline[0], Vector2.ZERO)
	for point in outline:
		area = area.expand(point)
	var from := Vector2i(((area.position - _origin) / cell_size).floor()).clamp(Vector2i.ZERO, _size)
	var to := Vector2i(((area.end - _origin) / cell_size).ceil()).clamp(Vector2i.ZERO, _size)
	for z in range(from.y, to.y):
		for x in range(from.x, to.x):
			var center := _origin + (Vector2(x, z) + Vector2(0.5, 0.5)) * cell_size
			if Geometry2D.is_point_in_polygon(center, outline):
				var cell := (z + _pad) * _width + x + _pad
				_heights[cell] = maxf(_heights[cell], top)


func _on_terrain_changed(_rect: Rect2i) -> void:
	_occlusion_dirty = true


# --- Helpers -------------------------------------------------------------------

## The padded-grid cell of a world point, clamped onto the map (noh CGameServer::GetVision).
func _cell_index(point: Vector3) -> int:
	var x := clampi(floori((point.x - _origin.x) / cell_size), 0, _size.x - 1)
	var z := clampi(floori((point.z - _origin.y) / cell_size), 0, _size.y - 1)
	return (z + _pad) * _width + x + _pad


## The full-screen pass that darkens the fog (CFogofWar::Render).
func _create_quad() -> void:
	_material.shader = SHADER
	_material.render_priority = Material.RENDER_PRIORITY_MAX  # after every other transparent pass
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.0, 2.0)
	_quad = MeshInstance3D.new()
	_quad.name = "FogPass"
	_quad.mesh = mesh
	_quad.material_override = _material
	_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_quad.extra_cull_margin = 16384.0  # placed in clip space by the shader; never culled
	add_child(_quad)
