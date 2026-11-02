extends SceneTree
## Imports a whole Heroes of Newerth map from NoH's game data as a map of this game.
##
##   python3 tools/noh/k2_to_gltf.py "<NoH>/Heroes of Newerth/game" assets/environment/hon \
##       world/props world/cliffs world/river buildings
##   godot --headless --path . --script res://tools/noh/noh_map.gd -- "<NoH>/Heroes of Newerth/game" \
##       [--map caldavar] [--rewrite] [--scene]
##
## It only writes what isn't there yet, so edits made in the editor (a camp's size, a tree's
## footprint, sculpted terrain) stay: --rewrite writes everything below again from HoN's data,
## and --scene the map scene itself.
##
## From maps/<map> it writes:
## - The terrain (data/terrain/<map>_terrain.res): HoN's heights, its ground textures (the most
##   used ones become a tileset, data/terrain/<map>_tileset.tres, with the textures in
##   assets/environment/hon/terrain), its vertex colors as the terrain's tint, and its pathing
##   (the vertex blocker map: a cell is blocked when all four corners are, as in NoH's
##   CNavigationMap) as the terrain's blockers. The map scene also blocks slopes past 55 degrees:
##   thin blocker lines leave walkable gaps in the cliffs.
## - What stands on it, one scene each in scenes/maps/<map>/: trees (blocking movement and sight
##   like HoN's, Prop_Tree_OcclusionRadius around the trunk), cliffs (a CliffBatch: their tops show
##   the terrain) and props (decorations: the blocker map already keeps units off cliffs),
##   buildings (blocking), water.
## - The lanes (scenes/maps/<map>/lanes.tscn): HoN's lane nodes and a CreepSpawner on each creep
##   spawner, following its chain of nodes, with the creeps main.tscn's spawners send.
## - The jungle (scenes/maps/<map>/camps.tscn): a NeutralCamp on each camp controller with its
##   groups of creatures, and one for the boss (Kongor). The creatures become unit definitions in
##   data/units/creatures, from HoN's npc entities (stats scaled by CREATURE_*), each with its own
##   HoN model where it's been converted (scenes/characters/hon: k2_unit_to_gltf.py, make_noh_prefabs.py),
##   else a character prefab standing in for it (CREATURE_MODELS).
## - With --scene, or when it doesn't exist yet: the map itself, scenes/maps/<map>.tscn: main.tscn's
##   game setup (registry, commander, HUD, fog, waves...) on the new terrain, with the scenes
##   above, the heroes starting at team 1's spawn point, and the map's sunlight.
##
## Positions keep HoN's scale, 48 units per meter, the map's middle at the origin, north up -Z;
## models turn like in K2 (CAxis: pitch, roll, yaw). The models come from tools/noh/k2_to_gltf.py;
## ones it didn't convert (effects, critters, the editor's markers) are left out.

const UNITS_PER_METER := 48.0
const HON := "res://assets/environment/hon"
const TERRAIN_TEXTURES := HON + "/terrain"
const MAIN := "res://scenes/main.tscn"
const SKIP_MODELS: Array[String] = ["/core/", "/tools/", "/shared/", "/npcs/", "/effects/"]
const TREE_BLOCKER := 50.0 / UNITS_PER_METER  ## game_settings.cfg Prop_Tree_OcclusionRadius
const TREE_SEE_THROUGH := 2.0
const BUILDING_FOOTPRINT := 0.8  ## of their convex hull: towers and halls have overhangs
const WATER_COLOR := Color(0.18, 0.38, 0.42, 0.55)
const CREATURES := "res://data/units/creatures"
## HoN's neutral creatures as this game's units: which character prefab (scenes/characters) stands
## in for each without a converted model (by the longest matching part of its HoN name), and how its HoN stats translate to
## this game's pace (its creeps are slower than HoN's, 3.6-4 m/s against 6.8).
const CREATURE_MODELS := {
	"kongor": "barbarian", "minotaur": "barbarian", "ogre": "barbarian", "werebeastenchanter": "skeleton_mage",
	"werebeast": "barbarian", "crusher": "barbarian", "skeletonboss": "skeleton_warrior", "snotterlarge": "barbarian",
	"wolfcommander": "skeleton_warrior", "catman": "skeleton_rogue", "dragon": "water_elemental", "ebula": "skeleton_mage",
	"screacher": "skeleton_mage", "vulture": "skeleton_mage", "goat": "skeleton_minion", "snottling": "skeleton_minion",
	"wolf": "skeleton_minion", "hunterwarrior": "skeleton_warrior", "predasaur": "skeleton_rogue", "skeleton": "skeleton_warrior",
}
const CREATURE_HEALTH := 0.8
const CREATURE_DAMAGE := 0.8
const CREATURE_SPEED := 0.6
const CREATURE_EXPERIENCE := 0.6
const CREATURE_AGGRO := 2.0  ## meters: they keep to themselves until attacked (HoN neutrals don't aggro)
const CREATURE_SIZE := 0.7  ## of HoN's model scale, between CREATURE_SIZE_RANGE
const CREATURE_SIZE_RANGE := Vector2(0.6, 1.5)
const BOSS_SIZE := 2.2
const CAMP_RESPAWN := 60.0  ## HoN: every minute, if the camp is empty
const BOSS_RESPAWN := 600.0
const TAR_COLOR := Color(0.05, 0.03, 0.04, 0.9)

var _game := ""
var _rewrite := false  ## --rewrite: write over what's already there
var _map := "caldavar"
var _folder := ""  ## the map's scenes
var _world_name := ""
var _tiles := 512  ## per side
var _tile_units := 32.0
var _texture_tiles := 16.0  ## tiles per repeat of a ground texture
var _sun := Vector2(50.0, 30.0)  ## altitude, azimuth (degrees)
var _glbs := {}  ## lower-case path under HON -> res path
var _entities: Array[Dictionary] = []
var _by_name := {}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var rest: Array[String] = []
	var write_scene := false
	var i := 0
	while i < args.size():
		if args[i] == "--map" and i + 1 < args.size():
			_map = args[i + 1]
			i += 2
			continue
		if args[i] == "--scene":
			write_scene = true
		elif args[i] == "--rewrite":
			_rewrite = true
		else:
			rest.append(args[i])
		i += 1
	if rest.size() != 1:
		printerr("usage: godot --headless --path . --script res://tools/noh/noh_map.gd -- <HoN game folder> [--map caldavar] [--scene]")
		quit(1)
		return
	_game = rest[0]
	_folder = "res://scenes/maps/%s" % _map
	var source := _game.path_join("maps").path_join(_map)
	if not FileAccess.file_exists(source.path_join("worldconfig")):
		printerr("no map at %s" % source)
		quit(1)
		return
	_read_world_config(source.path_join("worldconfig"))
	_read_entities(source.path_join("entitylist"))
	_index_models(HON)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_folder))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TERRAIN_TEXTURES))

	var started := Time.get_ticks_msec()
	_import_terrain(source)
	print("terrain: %.1f s" % ((Time.get_ticks_msec() - started) / 1000.0))
	_write_contents()
	_write_lanes()
	_write_camps()
	# The new textures and models must be imported before the map scene can load them
	var output := []
	OS.execute(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--import"], output, true)
	var scene_path := "res://scenes/maps/%s.tscn" % _map
	if write_scene or not FileAccess.file_exists(scene_path):
		_write_map_scene(scene_path)
	else:
		print("kept %s (--scene rewrites it)" % scene_path)
	quit()


# --- Reading the map ---------------------------------------------------------------------------

func _read_world_config(path: String) -> void:
	var parser := XMLParser.new()
	parser.open(path)
	while parser.read() == OK:
		if parser.get_node_type() != XMLParser.NODE_ELEMENT:
			continue
		if parser.get_node_name() == "world":
			_world_name = parser.get_named_attribute_value_safe("name")
			_tiles = 1 << int(parser.get_named_attribute_value_safe("size"))
			_tile_units = float(parser.get_named_attribute_value_safe("scale"))
			_texture_tiles = float(parser.get_named_attribute_value_safe("texturescale"))
		elif parser.get_node_name() == "var":
			match parser.get_named_attribute_value_safe("name"):
				"scene_sunAltitude":
					_sun.x = float(parser.get_named_attribute_value_safe("value"))
				"scene_sunAzimuth":
					_sun.y = float(parser.get_named_attribute_value_safe("value"))


func _read_entities(path: String) -> void:
	var parser := XMLParser.new()
	parser.open(path)
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT and parser.get_node_name() == "entity":
			var entity := {}
			for a in parser.get_attribute_count():
				entity[parser.get_attribute_name(a)] = parser.get_attribute_value(a)
			_entities.append(entity)
			if not String(entity.get("name", "")).is_empty():
				_by_name[entity.name] = entity


func _index_models(folder: String) -> void:
	for file in DirAccess.get_files_at(folder):
		if file.ends_with(".glb"):
			var path := folder.path_join(file)
			_glbs[path.trim_prefix(HON + "/").to_lower()] = path
	for sub in DirAccess.get_directories_at(folder):
		_index_models(folder.path_join(sub))


## The converted model of an entity ("/world/cliffs/Legion/A_F.mdf" -> cliffs/legion/a_f.glb), or "".
func _model(entity: Dictionary) -> String:
	var mdf: String = entity.get("model", "")
	for skip in SKIP_MODELS:
		if mdf.to_lower().contains(skip):
			return ""
	var relative := mdf.trim_prefix("/").trim_prefix("world/").to_lower()
	var stem := relative.get_file().get_basename().trim_suffix("_high")
	var folder := relative.get_base_dir()
	var name := folder.get_file() if stem == "model" else stem
	return _glbs.get(folder.path_join(name + ".glb"), "")


func _hon_vector(text: String) -> Vector3:
	var values := text.split(" ")
	return Vector3(float(values[0]), float(values[1]), float(values[2])) if values.size() >= 3 else Vector3.ZERO


## HoN position (units, Z up) -> meters on the map: x east, y up, z south, the middle at the origin.
func _to_map(hon: Vector3) -> Vector3:
	var half := _tiles * _tile_units * 0.5
	return Vector3((hon.x - half) / UNITS_PER_METER, hon.z / UNITS_PER_METER, -(hon.y - half) / UNITS_PER_METER)


## The entity's placement: K2's CAxis(pitch, roll, yaw) turned into Godot's axes, scaled.
func _transform(entity: Dictionary, on_ground := false) -> Transform3D:
	var angles := _hon_vector(entity.get("angles", "0 0 0"))
	var sp := sin(deg_to_rad(angles.x))
	var cp := cos(deg_to_rad(angles.x))
	var sr := sin(deg_to_rad(angles.y))
	var cr := cos(deg_to_rad(angles.y))
	var sy := sin(deg_to_rad(angles.z))
	var cy := cos(deg_to_rad(angles.z))
	var hon := Basis(Vector3(cr * cy - sr * sp * sy, cr * sy + sr * sp * cy, -sr * cp),
			Vector3(-cp * sy, cp * cy, sp),
			Vector3(sr * cy + cr * sp * sy, sr * sy - cr * sp * cy, cr * cp))
	var to_godot := Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0))  # x, y, z -> x, z, -y
	var turned := to_godot * hon * to_godot.transposed()
	var scale := float(entity.get("scale", "1"))
	var origin := _to_map(_hon_vector(entity.get("position", "0 0 0")))
	if on_ground:
		origin.y = 0.0
	return Transform3D(Basis(turned.x * scale, turned.y * scale, turned.z * scale), origin)


# --- Terrain -----------------------------------------------------------------------------------

func _import_terrain(source: String) -> void:
	if _kept("res://data/terrain/%s_terrain.res" % _map) and _kept("res://data/terrain/%s_tileset.tres" % _map):
		return
	var vertices := _tiles + 1
	var heights := _read_heights(source.path_join("heightmap"), vertices)
	var colors := _read_grid(source.path_join("vertexcolormap"), vertices, 4)
	var blockers := _read_grid(source.path_join("vertexblockermap"), vertices, 1)
	var layers := _read_tile_layers(source.path_join("tilematerialmap"))
	var names := _read_texture_list(source.path_join("texturelist"))

	# How much of the second layer shows: HoN mixes it in by the vertex alpha times its texture's alpha
	var opacity := {}
	for id: int in names:
		opacity[id] = _texture_opacity(names[id])
	# The ground texture that shows most at each vertex, from the tiles around it
	var shown := PackedInt32Array()
	shown.resize(vertices * vertices)
	var counts := {}
	for vy in vertices:
		for vx in vertices:
			var alpha := colors[(vy * vertices + vx) * 4 + 3] / 255.0
			var score := {}
			for ty in [vy - 1, vy]:
				for tx in [vx - 1, vx]:
					if tx < 0 or ty < 0 or tx >= _tiles or ty >= _tiles:
						continue
					var t: int = ty * _tiles + tx
					var top := alpha * float(opacity.get(layers[1][t], 0.0))
					score[layers[0][t]] = score.get(layers[0][t], 0.0) + 1.0 - top
					score[layers[1][t]] = score.get(layers[1][t], 0.0) + top
			var best := -1
			for id: int in score:
				if opacity.has(id) and (best < 0 or score[id] > score[best]):
					best = id
			shown[vy * vertices + vx] = best
			counts[best] = counts.get(best, 0) + 1
	# The most shown textures become the tileset; the rest take the closest-looking of those
	var ids: Array = counts.keys().filter(func(id: int) -> bool: return id >= 0)
	ids.sort_custom(func(a: int, b: int) -> bool: return counts[a] > counts[b])
	var chosen: Array = ids.slice(0, TerrainTileset.MAX_TILES)
	var color_of := {}
	for id: int in ids:
		color_of[id] = _texture_color(names[id])
	var tile_of := {-1: 0}
	for id: int in ids:
		var nearest := 0
		for k in chosen.size():
			var a: Color = color_of[id]
			var b: Color = color_of[chosen[k]]
			var c: Color = color_of[chosen[nearest]]
			if Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length() < Vector3(a.r - c.r, a.g - c.g, a.b - c.b).length():
				nearest = k
		tile_of[id] = chosen.find(id) if chosen.has(id) else nearest

	# Filled here and handed over whole: writing into a resource's packed array copies it every time
	var meters := PackedFloat32Array()
	meters.resize(vertices * vertices)
	var tile_ids := PackedByteArray()
	tile_ids.resize(vertices * vertices)
	var tint := PackedByteArray()
	tint.resize(vertices * vertices * 3)
	for z in vertices:
		var hon_row := (_tiles - z) * vertices  # our rows run south, HoN's north
		for x in vertices:
			var ours := z * vertices + x
			meters[ours] = heights[hon_row + x] / UNITS_PER_METER
			tile_ids[ours] = tile_of[shown[hon_row + x]]
			for c in 3:
				tint[ours * 3 + c] = colors[(hon_row + x) * 4 + c]
	var blocked := PackedByteArray()
	blocked.resize(_tiles * _tiles)
	for cz in _tiles:
		var top := (_tiles - cz) * vertices
		var bottom := (_tiles - cz - 1) * vertices
		for cx in _tiles:
			var all := blockers[top + cx] != 0 and blockers[top + cx + 1] != 0 and blockers[bottom + cx] != 0 \
					and blockers[bottom + cx + 1] != 0
			blocked[cz * _tiles + cx] = 1 if all else 0
	var data := TerrainData.create(Vector2i(_tiles, _tiles), _tile_units / UNITS_PER_METER)
	data.heights = meters
	data.tiles = tile_ids
	data.tint = tint
	data.blockers = blocked
	var data_path := "res://data/terrain/%s_terrain.res" % _map
	print("terrain data ", error_string(ResourceSaver.save(data, data_path)))
	_write_tileset(chosen, names, "res://data/terrain/%s_tileset.tres" % _map)
	var used := PackedStringArray()
	for id: int in chosen:
		used.append("%s %d" % [_texture_name(names[id]), counts[id]])
	print("tileset (vertices showing each): ", ", ".join(used))


func _read_heights(path: String, vertices: int) -> PackedFloat32Array:
	var file := FileAccess.open(path, FileAccess.READ)
	var width := _signed(file.get_32())
	file.get_32()
	var heights := PackedFloat32Array()
	heights.resize(vertices * vertices)
	var count := vertices * vertices
	if width < 0:  # 3 bytes per height, plane by plane (NoH CHeightMap::Load)
		var bytes := file.get_buffer(count * 3)
		for i in count:
			heights[i] = bytes[i] / 256.0 + bytes[count + i] + bytes[count * 2 + i] * 256.0 - 32768.0
	else:
		for i in count:
			heights[i] = file.get_float()
	return heights


## A per-vertex map with a width and height up front: `channels` bytes per vertex.
func _read_grid(path: String, vertices: int, channels: int) -> PackedByteArray:
	var file := FileAccess.open(path, FileAccess.READ)
	file.get_32()
	file.get_32()
	return file.get_buffer(vertices * vertices * channels)


## Each tile's diffuse texture id on the two layers (NoH CTileMaterialMap::Load).
func _read_tile_layers(path: String) -> Array[PackedInt32Array]:
	var file := FileAccess.open(path, FileAccess.READ)
	var layer_count := file.get_32()
	var packed := _signed(file.get_32()) < 0
	file.get_32()
	var stride := 20 if packed else 40
	var layers: Array[PackedInt32Array] = []
	for layer in layer_count:
		var ids := PackedInt32Array()
		ids.resize(_tiles * _tiles)
		var bytes := file.get_buffer(_tiles * _tiles * stride)
		for t in _tiles * _tiles:
			ids[t] = bytes.decode_s16(t * stride + 2) if packed else bytes.decode_s32(t * stride + 4)
		layers.append(ids)
	return layers


func _read_texture_list(path: String) -> Dictionary:
	var names := {}
	var parser := XMLParser.new()
	parser.open(path)
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT and parser.get_node_name() == "texture":
			var texture := parser.get_named_attribute_value_safe("name")
			if texture.begins_with("/") and texture.ends_with("_d.tga"):  # colors only; "$checker" is an empty layer
				names[int(parser.get_named_attribute_value_safe("id"))] = texture
	return names


func _signed(value: int) -> int:
	return value - 0x100000000 if value >= 0x80000000 else value


func _texture_file(texture: String) -> String:
	return _game.path_join(texture.trim_prefix("/").get_basename() + ".png")


func _texture_name(texture: String) -> String:
	return texture.get_file().get_basename().trim_suffix("_d")


func _texture_opacity(texture: String) -> float:
	var image := Image.load_from_file(_texture_file(texture))
	if image == null or image.is_empty():
		return 0.0
	if not image.detect_alpha():
		return 1.0
	return _mean(image).a


func _texture_color(texture: String) -> Color:
	var image := Image.load_from_file(_texture_file(texture))
	return _mean(image) if image != null and not image.is_empty() else Color.GRAY


## The average color: halving the image down to one pixel averages every texel.
func _mean(image: Image) -> Color:
	var small := image.duplicate() as Image
	small.convert(Image.FORMAT_RGBA8)
	while small.get_width() > 1 or small.get_height() > 1:
		small.resize(maxi(small.get_width() >> 1, 1), maxi(small.get_height() >> 1, 1), Image.INTERPOLATE_BILINEAR)
	return small.get_pixel(0, 0)


## The tileset: each chosen HoN texture with a height texture from its brightness (bright stones
## and tufts win where tiles meet), repeating every `texturescale` tiles like in HoN.
func _write_tileset(chosen: Array, names: Dictionary, path: String) -> void:
	var lines: Array[String] = ["[gd_resource type=\"Resource\" script_class=\"TerrainTileset\" format=3]", ""]
	lines.append("[ext_resource type=\"Script\" path=\"res://scripts/terrain/terrain_tileset.gd\" id=\"tileset\"]")
	lines.append("[ext_resource type=\"Script\" path=\"res://scripts/terrain/terrain_tile.gd\" id=\"tile\"]")
	var tiles: Array[String] = []
	var meters := _texture_tiles * _tile_units / UNITS_PER_METER
	var subs: Array[String] = []
	for k in chosen.size():
		var name := _texture_name(names[chosen[k]])
		var image := Image.load_from_file(_texture_file(names[chosen[k]]))
		image.convert(Image.FORMAT_RGB8)
		var albedo := TERRAIN_TEXTURES.path_join(name + ".png")
		image.save_png(ProjectSettings.globalize_path(albedo))
		var height := image.duplicate() as Image
		height.convert(Image.FORMAT_L8)
		var height_path := TERRAIN_TEXTURES.path_join(name + "_height.png")
		height.save_png(ProjectSettings.globalize_path(height_path))
		lines.append("[ext_resource type=\"Texture2D\" path=\"%s\" id=\"a%d\"]" % [albedo, k])
		lines.append("[ext_resource type=\"Texture2D\" path=\"%s\" id=\"h%d\"]" % [height_path, k])
		subs += ["", "[sub_resource type=\"Resource\" id=\"t%d\"]" % k, "script = ExtResource(\"tile\")",
				"name = \"%s\"" % name, "albedo = ExtResource(\"a%d\")" % k, "height = ExtResource(\"h%d\")" % k,
				"texture_meters = %s" % String.num(meters, 4)]
		tiles.append("SubResource(\"t%d\")" % k)
	lines += subs
	lines += ["", "[resource]", "script = ExtResource(\"tileset\")",
			"tiles = Array[ExtResource(\"tile\")]([%s])" % ", ".join(tiles), "texture_size = 512"]
	_save_text(path, lines)


# --- What stands on the map --------------------------------------------------------------------

func _write_contents() -> void:
	var trees: Array[Dictionary] = []
	var cliffs: Array[Dictionary] = []
	var props: Array[Dictionary] = []
	var buildings: Array[Dictionary] = []
	var water: Array[Dictionary] = []
	var missing := {}
	for entity in _entities:
		var type: String = entity.get("type", "")
		if not (type.begins_with("Prop_") or type.begins_with("Building_")):
			continue
		var model := _model(entity)
		if model.is_empty():
			if not _is_skipped(entity):
				missing[entity.get("model", "")] = true
			continue
		var entry := {"entity": entity, "model": model}
		match type:
			"Prop_Tree":
				trees.append(entry)
			"Prop_Cliff", "Prop_Cliff2":
				cliffs.append(entry)
			"Prop_Water":
				water.append(entry)
			_:
				(buildings if type.begins_with("Building_") else props).append(entry)
	var tree_radius := {}
	for entry in trees:
		if not tree_radius.has(entry.model):
			tree_radius[entry.model] = _model_radius(entry.model)
	_write_props("Trees", trees, func(entry: Dictionary, scale: float) -> Array[String]:
		var reach: float = tree_radius[entry.model] * scale
		return ["footprint = 2", "footprint_scale = %.3f" % (minf(TREE_BLOCKER, reach * 0.6) / reach),
				"see_through_scale = %.1f" % TREE_SEE_THROUGH])
	var decoration := func(_entry: Dictionary, _scale: float) -> Array[String]:
		return ["blocks_movement = false", "see_through = false"]
	_write_props("Cliffs", cliffs, decoration, "res://scripts/map/cliff_batch.gd")  # tops show the terrain
	_write_props("Props", props, decoration)
	_write_props("Buildings", buildings, func(_entry: Dictionary, _scale: float) -> Array[String]:
		return ["footprint_scale = %.2f" % BUILDING_FOOTPRINT, "blocks_vision = false", "see_through_scale = 2.0"])
	_write_water(water)
	print("trees %d, cliffs %d, props %d, buildings %d, water %d" % [trees.size(), cliffs.size(), props.size(),
			buildings.size(), water.size()])
	if not missing.is_empty():
		print("no converted model for: ", ", ".join(PackedStringArray(missing.keys())))


func _is_skipped(entity: Dictionary) -> bool:
	var mdf: String = String(entity.get("model", "")).to_lower()
	for skip in SKIP_MODELS:
		if mdf.contains(skip):
			return true
	return false


## MapProps under a MapPropBatch, at HoN's exact places (keep_on_ground off: tilted rocks stay
## tilted, cliff pieces at their heights). `settings(entry, scale)` adds lines to each.
func _write_props(group: String, entries: Array[Dictionary], settings: Callable,
		batch := "res://scripts/map/map_prop_batch.gd") -> void:
	if _kept(_scene(group)):
		return
	var models := {}
	for entry in entries:
		models[entry.model] = true
	var lines: Array[String] = ["[gd_scene format=3%s]" % _uid_of(_scene(group)), ""]
	lines.append("[ext_resource type=\"Script\" path=\"%s\" id=\"batch\"]" % batch)
	lines.append("[ext_resource type=\"Script\" path=\"res://scripts/map/map_prop.gd\" id=\"prop\"]")
	var ids := {}
	for model: String in models:
		ids[model] = "m%d" % ids.size()
		lines.append("[ext_resource type=\"PackedScene\" path=\"%s\" id=\"%s\"]" % [model, ids[model]])
	lines += ["", "[node name=\"%s\" type=\"Node3D\"]" % group, "script = ExtResource(\"batch\")"]
	var counts := {}
	for entry in entries:
		var base: String = entry.model.get_file().get_basename()
		var index: int = counts.get(base, 0)
		counts[base] = index + 1
		var place := _transform(entry.entity)
		lines += ["", "[node name=\"%s#%d\" parent=\".\" instance=ExtResource(\"%s\")]" % [base, index, ids[entry.model]],
				"transform = %s" % _text(place), "script = ExtResource(\"prop\")", "keep_on_ground = false"]
		lines += settings.call(entry, float(entry.entity.get("scale", "1")))
		lines.append("metadata/_edit_group_ = true")
	_save_text(_scene(group), lines)


## The rivers, the Legion's well and the Hellbourne's tar pit, each WaterSurface with its look
## (shaders/water.gdshader: fades out where the ground comes near the surface).
func _write_water(entries: Array[Dictionary]) -> void:
	if _kept(_scene("Water")):
		return
	var lines: Array[String] = ["[gd_scene format=3%s]" % _uid_of(_scene("Water")), ""]
	lines.append("[ext_resource type=\"Script\" path=\"res://scripts/map/water_surface.gd\" id=\"water\"]")
	var ids := {}
	for entry in entries:
		if not ids.has(entry.model):
			ids[entry.model] = "m%d" % ids.size()
			lines.append("[ext_resource type=\"PackedScene\" path=\"%s\" id=\"%s\"]" % [entry.model, ids[entry.model]])
	lines.append("[ext_resource type=\"Shader\" path=\"res://shaders/water.gdshader\" id=\"shader\"]")
	lines += ["", "[sub_resource type=\"ShaderMaterial\" id=\"water_look\"]", "render_priority = 0",
			"shader = ExtResource(\"shader\")", "shader_parameter/color = Color(%s)" % _color(WATER_COLOR),
			"", "[sub_resource type=\"ShaderMaterial\" id=\"tar_look\"]", "render_priority = 0",
			"shader = ExtResource(\"shader\")", "shader_parameter/color = Color(%s)" % _color(TAR_COLOR),
			"shader_parameter/roughness = 0.2", "shader_parameter/metallic = 0.0"]
	lines += ["", "[node name=\"Water\" type=\"Node3D\"]",
			"", "[node name=\"River\" type=\"Node3D\" parent=\".\"]", "script = ExtResource(\"water\")",
			"material = SubResource(\"water_look\")",
			"", "[node name=\"Tar\" type=\"Node3D\" parent=\".\"]", "script = ExtResource(\"water\")",
			"material = SubResource(\"tar_look\")"]
	var counts := {}
	for entry in entries:
		var base: String = entry.model.get_file().get_basename()
		var index: int = counts.get(base, 0)
		counts[base] = index + 1
		var parent := "Tar" if base.contains("tar") else "River"
		lines += ["", "[node name=\"%s#%d\" parent=\"%s\" instance=ExtResource(\"%s\")]" % [base, index, parent, ids[entry.model]],
				"transform = %s" % _text(_transform(entry.entity))]
	_save_text(_scene("Water"), lines)


## The lane nodes and a CreepSpawner on each of HoN's creep spawners, its lane the chain of
## nodes its target0 starts. The creeps are the ones main.tscn's spawners send for that team.
func _write_lanes() -> void:
	if _kept(_scene("Lanes")):
		return
	var sends := _main_spawners()
	var lines: Array[String] = ["[gd_scene format=3%s]" % _uid_of(_scene("Lanes")), ""]
	lines.append("[ext_resource type=\"Script\" path=\"res://scripts/rts/creep_spawner.gd\" id=\"spawner\"]")
	var resources := {}
	for team: int in sends:
		for key: String in sends[team]:
			if key == "creep_scale":
				continue
			var path: String = sends[team][key]
			if not resources.has(path):
				resources[path] = "r%d" % resources.size()
				lines.append("[ext_resource type=\"Resource\" path=\"%s\" id=\"%s\"]" % [path, resources[path]])
	lines += ["", "[node name=\"Lanes\" type=\"Node3D\"]", "", "[node name=\"LaneNodes\" type=\"Node3D\" parent=\".\"]"]
	for entity in _entities:
		if entity.get("type") == "Entity_LaneNode":
			lines += ["", "[node name=\"%s\" type=\"Marker3D\" parent=\"LaneNodes\"]" % entity.name,
					"transform = %s" % _text(Transform3D(Basis.IDENTITY, _to_map(_hon_vector(entity.position)) * Vector3(1, 0, 1)))]
	var spawners := 0
	for entity in _entities:
		if entity.get("type") != "Entity_CreepSpawner":
			continue
		var team := int(entity.get("team", "1"))
		var chain: Array[String] = []
		var next: String = entity.get("target0", "")
		while _by_name.has(next) and _by_name[next].get("type") == "Entity_LaneNode" and not chain.has(next):
			chain.append(next)
			next = _by_name[next].get("target0", "")
		lines += ["", "[node name=\"%s\" type=\"Marker3D\" parent=\".\" node_paths=PackedStringArray(\"lane_nodes\")]" % entity.name,
				"transform = %s" % _text(Transform3D(Basis.IDENTITY, _to_map(_hon_vector(entity.position)) * Vector3(1, 0, 1))),
				"script = ExtResource(\"spawner\")", "team = %d" % team,
				"lane_nodes = [%s]" % ", ".join(chain.map(func(node: String) -> String: return "NodePath(\"../LaneNodes/%s\")" % node))]
		var send: Dictionary = sends.get(team, sends.get(1, {}))
		for key: String in send:
			lines.append("%s = %s" % [key, "ExtResource(\"%s\")" % resources[send[key]] if key != "creep_scale" else send[key]])
		spawners += 1
	_save_text(_scene("Lanes"), lines)
	print("lanes: %d spawners" % spawners)


## What main.tscn's spawners send, by team: {team: {melee: path, ranged: path, ..., creep_scale: value}}.
func _main_spawners() -> Dictionary:
	var state := (load(MAIN) as PackedScene).get_state()
	var sends := {}
	for n in state.get_node_count():
		var team := 1
		var send := {}
		var is_spawner := false
		for p in state.get_node_property_count(n):
			var key := String(state.get_node_property_name(n, p))
			var value: Variant = state.get_node_property_value(n, p)
			if key == "script" and value is Script and (value as Script).resource_path.ends_with("creep_spawner.gd"):
				is_spawner = true
			elif key == "team":
				team = value
			elif key in ["melee", "ranged", "siege", "hero"] and value is Resource:
				send[key] = (value as Resource).resource_path
			elif key == "creep_scale":
				send[key] = String.num(value, 3)
		if is_spawner:
			sends[team] = send
	return sends


## The model's widest reach from the middle of its bounds, seen from above, unscaled: as MapProp
## measures the footprint it scales by footprint_scale.
func _model_radius(path: String) -> float:
	var node: Node3D = (load(path) as PackedScene).instantiate()
	var points := PackedVector3Array()
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mesh := child as MeshInstance3D
		var to_model := Transform3D.IDENTITY  # not in the tree: no global transforms
		var at: Node = mesh
		while at != node:
			to_model = (at as Node3D).transform * to_model
			at = at.get_parent()
		for vertex in mesh.mesh.get_faces():
			points.append(to_model * vertex)
	node.free()
	var bounds := AABB(points[0], Vector3.ZERO)
	for point in points:
		bounds = bounds.expand(point)
	var center := bounds.get_center()
	var radius := 0.0
	for point in points:
		radius = maxf(radius, Vector2(point.x - center.x, point.z - center.z).length())
	return radius


# --- The jungle ----------------------------------------------------------------------------------

## A NeutralCamp on each camp controller (its target0..3 lists are the groups, one sent at a time)
## and one on the boss spawner.
func _write_camps() -> void:
	if _kept(_scene("Camps")):
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CREATURES))
	var definitions := {}  # HoN type -> {path, gold}
	var camps: Array[Dictionary] = []
	for entity in _entities:
		var type: String = entity.get("type", "")
		if type == "Entity_NeutralCampController":
			var camp := {"name": entity.name, "at": _to_map(_hon_vector(entity.position)) * Vector3(1, 0, 1),
					"respawn": CAMP_RESPAWN, "members": []}
			for group in 4:
				for member: String in String(entity.get("target%d" % group, "")).split(",", false):
					if _by_name.has(member):
						camp.members.append({"entity": _by_name[member], "group": group,
								"size": clampf(float(_by_name[member].get("scale", "1")) * CREATURE_SIZE,
										CREATURE_SIZE_RANGE.x, CREATURE_SIZE_RANGE.y)})
			camps.append(camp)
		elif type == "Entity_BossSpawner":
			camps.append({"name": entity.get("name", "Boss"), "at": _to_map(_hon_vector(entity.position)) * Vector3(1, 0, 1),
					"respawn": BOSS_RESPAWN, "members": [{"entity": entity, "group": 0, "size": BOSS_SIZE}]})
	for camp in camps:
		for member: Dictionary in camp.members:
			var kind: String = member.entity.get("target0", "")
			if not definitions.has(kind):
				definitions[kind] = _write_creature(kind)
	var lines: Array[String] = ["[gd_scene format=3%s]" % _uid_of(_scene("Camps")), ""]
	lines.append("[ext_resource type=\"Script\" path=\"res://scripts/rts/neutral_camp.gd\" id=\"camp\"]")
	var ids := {}
	for kind: String in definitions:
		if not definitions[kind].is_empty():
			ids[kind] = "c%d" % ids.size()
			lines.append("[ext_resource type=\"Resource\" path=\"%s\" id=\"%s\"]" % [definitions[kind].path, ids[kind]])
	lines += ["", "[node name=\"Camps\" type=\"Node3D\"]"]
	var count := 0
	for camp in camps:
		var creatures: Array[String] = []
		var spots: Array[String] = []
		var sizes: Array[String] = []
		var groups: Array[String] = []
		var gold: Array[String] = []
		for member: Dictionary in camp.members:
			var kind: String = member.entity.get("target0", "")
			if not ids.has(kind):
				continue
			var offset: Vector3 = _to_map(_hon_vector(member.entity.position)) * Vector3(1, 0, 1) - camp.at
			creatures.append("ExtResource(\"%s\")" % ids[kind])
			spots.append("%s, 0, %s" % [String.num(offset.x, 3), String.num(offset.z, 3)])
			sizes.append(String.num(member.size, 2))
			groups.append(str(member.group))
			gold.append(str(definitions[kind].gold))
		if creatures.is_empty():
			continue
		lines += ["", "[node name=\"%s\" type=\"Marker3D\" parent=\".\"]" % camp.name,
				"transform = %s" % _text(Transform3D(Basis.IDENTITY, camp.at)), "script = ExtResource(\"camp\")",
				"team = %d" % UnitRegistry.CREATURE_TEAM, "active = false",
				"creatures = Array[ExtResource(\"%s\")]([%s])" % ["unit_definition", ", ".join(creatures)],
				"spots = PackedVector3Array(%s)" % ", ".join(spots), "sizes = PackedFloat32Array(%s)" % ", ".join(sizes),
				"groups = PackedInt32Array(%s)" % ", ".join(groups), "gold = PackedInt32Array(%s)" % ", ".join(gold),
				"respawn_time = %s" % String.num(camp.respawn, 1)]
		count += 1
	lines.insert(3, "[ext_resource type=\"Script\" path=\"res://scripts/rts/unit_definition.gd\" id=\"unit_definition\"]")
	_save_text(_scene("Camps"), lines)
	print("camps: %d, creatures: %s" % [count, ", ".join(PackedStringArray(definitions.keys()))])


## A HoN neutral (its npc entity's stats) as a unit definition in CREATURES: {path, gold}, or {}.
func _write_creature(kind: String) -> Dictionary:
	var stats := _npc_stats(kind)
	if stats.is_empty():
		print("no npc entity for ", kind)
		return {}
	var key := kind.to_lower().trim_prefix("neutral_").replace("_", "")
	var model := ""
	var longest := 0
	for part: String in CREATURE_MODELS:
		if key.contains(part) and part.length() > longest:
			longest = part.length()
			model = CREATURE_MODELS[part]
	var definition := UnitDefinition.new()
	definition.display_name = _display_name(kind)
	var own := "res://scenes/characters/hon/%s.tscn" % stats.get("_folder", "")
	if ResourceLoader.exists(own):
		definition.model = load(own)
	else:
		definition.model = load("res://scenes/characters/%s.tscn" % (model if not model.is_empty() else "skeleton_warrior"))
	definition.max_health = roundf(float(stats.get("maxhealth", "300")) * CREATURE_HEALTH)
	definition.armor = float(stats.get("armor", "0"))
	definition.move_speed = snappedf(float(stats.get("movespeed", "300")) / UNITS_PER_METER * CREATURE_SPEED, 0.1)
	definition.aggro_range = CREATURE_AGGRO
	var damage := (float(stats.get("attackdamagemin", "20")) + float(stats.get("attackdamagemax", "20"))) * 0.5
	definition.attack_damage = roundf(damage * CREATURE_DAMAGE)
	definition.attack_cooldown = float(stats.get("attackcooldown", "1700")) / 1000.0
	var ranged: bool = stats.get("attacktype", "melee") == "ranged"
	definition.attack_range = float(stats.get("attackrange", "500")) / UNITS_PER_METER if ranged else 1.2
	definition.projectile_speed = 14.0 if ranged else 0.0
	definition.bounty_experience = roundf(float(stats.get("experiencebounty", "40")) * CREATURE_EXPERIENCE)
	var path := CREATURES.path_join(key + ".tres")
	ResourceSaver.save(definition, path)
	var gold := roundi((float(stats.get("goldbountymin", "0")) + float(stats.get("goldbountymax", stats.get("goldbountymin", "0")))) * 0.5)
	return {"path": path, "gold": gold}


## The attributes of the npc entity named `kind` (game/npcs/*/*.entity).
func _npc_stats(kind: String) -> Dictionary:
	var npcs := _game.path_join("npcs")
	for folder in DirAccess.get_directories_at(npcs):
		for file in DirAccess.get_files_at(npcs.path_join(folder)):
			if not file.ends_with(".entity"):
				continue
			var parser := XMLParser.new()
			if parser.open(npcs.path_join(folder).path_join(file)) != OK:
				continue
			while parser.read() == OK:
				if parser.get_node_type() == XMLParser.NODE_ELEMENT:
					if parser.get_named_attribute_value_safe("name").to_lower() == kind.to_lower():
						var stats := {"_folder": folder}  # its npc folder: its model's
						for a in parser.get_attribute_count():
							stats[parser.get_attribute_name(a)] = parser.get_attribute_value(a)
						return stats
					break  # only the root element names the entity
	return {}


## "Neutral_WerebeastEnchanter" -> "Werebeast Enchanter".
func _display_name(kind: String) -> String:
	return kind.capitalize().trim_prefix("Neutral ")


# --- The map -----------------------------------------------------------------------------------

## main.tscn's game setup on the imported terrain, with the map's contents and lanes, the heroes
## starting at team 1's spawn point, the camera and fog of war over the whole map, HoN's sunlight.
func _write_map_scene(path: String) -> void:
	var map_root: Node3D = (load(MAIN) as PackedScene).instantiate()  # never enters the tree: nothing runs
	map_root.name = _map.capitalize().replace(" ", "")
	map_root.set(&"map_name", _world_name)
	var region: Node3D = map_root.get_node("NavigationRegion3D")
	for node in region.get_children():
		if node.name != "Terrain":
			node.free()
	for node_name in ["Props", "CaldavarForest", "LaneCenter", "SouthSpawner", "NorthSpawner", "ToVillage", "FromVillage"]:
		if map_root.has_node(NodePath(node_name)):
			map_root.get_node(NodePath(node_name)).free()
	var terrain: Terrain = region.get_node("Terrain")
	terrain.data = load("res://data/terrain/%s_terrain.res" % _map)
	terrain.tileset = load("res://data/terrain/%s_tileset.tres" % _map)
	# HoN's pathing is its blocker map, but a tile only blocks with all four corners blocked, so thin
	# blocker lines leave steep gaps in the cliffs (about 1,350 on Caldavar) that creeps chasing
	# something walk into. Slopes past this close them; Caldavar's lanes and ramps stay walkable.
	terrain.max_walkable_slope = 55.0

	var world := Node3D.new()
	world.name = "World"
	map_root.add_child(world)
	map_root.move_child(world, region.get_index() + 1)
	for group in ["Trees", "Cliffs", "Props", "Buildings", "Water"]:
		world.add_child((load(_scene(group)) as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE))
	var lanes: Node = (load(_scene("Lanes")) as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	map_root.add_child(lanes)
	map_root.move_child(lanes, world.get_index() + 1)
	var camps: Node = (load(_scene("Camps")) as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	map_root.add_child(camps)
	map_root.move_child(camps, lanes.get_index() + 1)

	for entity in _entities:
		if entity.get("type") == "Trigger_SpawnPoint" and entity.get("team") == "1":
			(map_root.get_node("HeroStart") as Node3D).position = _to_map(_hon_vector(entity.position)) * Vector3(1, 0, 1)
	var extent := _tiles * _tile_units / UNITS_PER_METER
	var bounds := Rect2(-extent * 0.5, -extent * 0.5, extent, extent)
	map_root.get_node("RTSCamera").set(&"bounds", bounds)
	map_root.get_node("FogOfWar").set(&"bounds", bounds)

	# Daylight from HoN's sun: altitude above the horizon, azimuth counter-clockwise from east
	var environment: WorldEnvironment = map_root.get_node("WorldEnvironment")
	environment.environment = environment.environment.duplicate()
	var sun: DirectionalLight3D = environment.get_node("Moon")
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.97, 0.9)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	var altitude := deg_to_rad(_sun.x)
	var azimuth := deg_to_rad(_sun.y)
	var to_sun := Vector3(cos(altitude) * cos(azimuth), sin(altitude), -cos(altitude) * sin(azimuth))
	sun.transform = Transform3D(Basis.looking_at(-to_sun, Vector3.UP), Vector3(0, 40, 0))

	for node in map_root.find_children("*", "", true, false):
		if node.owner == null:
			node.owner = map_root
	var packed := PackedScene.new()
	var packing := packed.pack(map_root)
	print("map scene ", error_string(packing), " ", error_string(ResourceSaver.save(packed, path)) if packing == OK else "")
	map_root.free()


# --- Writing -----------------------------------------------------------------------------------

## Whether `path` stays as it is: it exists and --rewrite wasn't given.
func _kept(path: String) -> bool:
	if _rewrite or not FileAccess.file_exists(path):
		return false
	print("kept ", path, " (--rewrite writes it again)")
	return true


func _scene(group: String) -> String:
	return _folder.path_join(group.to_lower() + ".tscn")


## ` uid="..."` of the scene already at `path`, so maps that instance it keep finding it; a new one otherwise.
func _uid_of(path: String) -> String:
	var uid := ResourceUID.id_to_text(ResourceUID.create_id())
	if FileAccess.file_exists(path):
		var found := RegEx.create_from_string("uid=\"(uid://[a-z0-9]+)\"").search(FileAccess.open(path, FileAccess.READ).get_line())
		if found != null:
			uid = found.get_string(1)
	return " uid=\"%s\"" % uid


## As a scene file writes it: the basis row by row (Transform3D(x.x, y.x, z.x, x.y, ...)), then the origin.
func _text(place: Transform3D) -> String:
	var values := PackedStringArray()
	for row in 3:
		for column in [place.basis.x, place.basis.y, place.basis.z]:
			values.append(String.num(column[row], 5))
	for axis in 3:
		values.append(String.num(place.origin[axis], 5))
	return "Transform3D(%s)" % ", ".join(values)


func _color(color: Color) -> String:
	return "%s, %s, %s, %s" % [String.num(color.r, 3), String.num(color.g, 3), String.num(color.b, 3), String.num(color.a, 3)]


func _save_text(path: String, lines: Array[String]) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()
	print("wrote ", path)
