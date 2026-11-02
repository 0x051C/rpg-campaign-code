extends SceneTree
## Writes the trees of a Heroes of Newerth map as a scene of MapProps under a MapPropBatch, to
## instance in one of this game's maps.
##
##   godot --headless --path . --script res://tools/noh/noh_forest.gd -- <HoN game folder> \
##       [--map res://scenes/main.tscn] [--out res://scenes/maps/forests/caldavar_forest.tscn] [--preview out.png]
##
## Caldavar's middle lane becomes the map's lane (SouthSpawner -> LaneCenter -> NorthSpawner):
## Legion's side south, Hellbourne's north, at HoN's own scale (48 units per meter), cropped to
## the map's terrain. Caldavar's lane bends a little; trees near it shift sideways so its edges
## follow the straight lane, while trees farther out keep their places. Trees are left out where
## they would stand on the lane (LANE_CLEAR), near the map's props, markers and spawners
## (CLEAR_RADIUS), or off the grass (roads, rock, planks: TREE_TILES), so the map's own layout
## stays as it is. Run it again after moving things on the map.
##
## The models come from tools/noh/k2_to_gltf.py (assets/environment/hon/props/trees). Every tree
## blocks movement and sight like in HoN: a footprint of Prop_Tree_OcclusionRadius (50 units,
## game_settings.cfg) whatever its size. It prints how much open ground the forest cuts off from
## the lane, and whether any clearing can't be reached; --preview draws it (dark: tree
## footprints, red: ground cut off, yellow: clearings).

const UNITS_PER_METER := 48.0
const MAP := "caldavar"
const TREES := "res://assets/environment/hon/props/trees"
## Caldavar's middle lane, Legion to Hellbourne: waypoints across from each other are its two sides.
const LANE: Array[String] = ["good_wypt_2_", "bad_wypt_2_"]
const PAIR_DISTANCE := 600.0  ## units: a good and a bad waypoint this close face each other across the lane
const EDGE := 1.0  ## meters in from the terrain's edge
const LANE_CLEAR := 7.0  ## meters each side of the lane's center line
const STRAIGHTEN_NEAR := 10.0  ## meters from Caldavar's lane: shifted all the way onto the straight lane
const STRAIGHTEN_FAR := 40.0  ## meters: not shifted any more
const CLEAR_RADIUS := 6.0  ## meters around the map's props and markers
const CLEAR_RADIUS_BY_NAME := {"SouthSpawner": 12.0, "NorthSpawner": 12.0, "HeroStart": 9.0, "LaneCenter": 9.0}
const CLEAR_PARENTS: Array[String] = [".", "Props", "NavigationRegion3D"]
const TREE_TILES: Array[int] = [0]  ## terrain tiles trees may stand on: grass in default_tileset
const TILE_CHECK := 1.5  ## meters around a trunk that must be on those tiles
const BLOCKER_RADIUS := 50.0 / UNITS_PER_METER  ## Prop_Tree_OcclusionRadius
const AGENT_RADIUS := 0.5  ## the navigation mesh's agent radius
const SEE_THROUGH_SCALE := 2.0
const GRID := 0.25  ## meters per cell of the reachability check

var _origin := Vector2.ZERO  ## the frame: HoN units of the lane's middle
var _axis := Vector2.ZERO  ## along the lane, towards Hellbourne
var _normal := Vector2.ZERO  ## to its right
var _lane: Array[Vector2] = []  ## (along, across) meters of Caldavar's lane, sorted


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var options := {"--map": "res://scenes/main.tscn", "--out": "res://scenes/maps/forests/%s_forest.tscn" % MAP, "--preview": ""}
	var rest: Array[String] = []
	var i := 0
	while i < args.size():
		if options.has(args[i]) and i + 1 < args.size():
			options[args[i]] = args[i + 1]
			i += 2
		else:
			rest.append(args[i])
			i += 1
	if rest.size() != 1:
		printerr("usage: godot --headless --path . --script res://tools/noh/noh_forest.gd -- <HoN game folder> [--map <tscn>] [--out <tscn>] [--preview <png>]")
		quit(1)
		return
	var entities := _read_entities(rest[0].path_join("maps/%s/entitylist" % MAP))
	if entities.is_empty():
		printerr("no entities in %s" % rest[0].path_join("maps/%s/entitylist" % MAP))
		quit(1)
		return
	_make_frame(entities)
	var map: SceneState = (load(options["--map"]) as PackedScene).get_state()
	var terrain := _terrain(map)
	var clearings := _clearings(map)
	var half := terrain.extent() * 0.5 - Vector2(EDGE, EDGE) if terrain != null else Vector2(79, 79)
	var kept: Array[Dictionary] = []
	var dropped := {"outside": 0, "lane": 0, "clearing": 0, "tile": 0}
	for entity in entities:
		if entity.get("type") != "Prop_Tree":
			continue
		var at := _place(_position(entity))
		if absf(at.x) > half.x or absf(at.y) > half.y:
			dropped.outside += 1
		elif absf(at.x) < LANE_CLEAR:
			dropped.lane += 1
		elif clearings.any(func(c: Vector3) -> bool: return at.distance_to(Vector2(c.x, c.y)) < c.z):
			dropped.clearing += 1
		elif terrain != null and not _on_tree_tiles(terrain, at):
			dropped.tile += 1
		else:
			var angles: PackedStringArray = (entity.get("angles", "0 0 0") as String).split(" ")
			kept.append({"model": (entity.get("model") as String).split("/")[-2], "at": at,
					"yaw": deg_to_rad(float(angles[2]) + 90.0 - rad_to_deg(_axis.angle())),
					"scale": float(entity.get("scale", "1"))})
	var counts := _write_scene(kept, options["--out"])
	print("%d trees (%s); left out: %s" % [kept.size(), _join(counts), _join(dropped)])
	_check(kept, clearings, half, options["--preview"])
	quit()


## The map's entities: their attributes by name.
func _read_entities(path: String) -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	var parser := XMLParser.new()
	if parser.open(path) != OK:
		return list
	while parser.read() == OK:
		if parser.get_node_type() == XMLParser.NODE_ELEMENT and parser.get_node_name() == "entity":
			var entity := {}
			for a in parser.get_attribute_count():
				entity[parser.get_attribute_name(a)] = parser.get_attribute_value(a)
			list.append(entity)
	return list


func _position(entity: Dictionary) -> Vector2:
	var values: PackedStringArray = (entity.get("position", "0 0 0") as String).split(" ")
	return Vector2(float(values[0]), float(values[1]))


## The frame: Caldavar's lane middle, its direction, and how it bends beside the straight axis.
func _make_frame(entities: Array[Dictionary]) -> void:
	var good: Array[Vector2] = []
	var bad: Array[Vector2] = []
	for entity in entities:
		var entity_name: String = entity.get("name", "")
		if entity.get("type") == "Entity_LaneNode" and entity_name.begins_with(LANE[0]):
			good.append(_position(entity))
		elif entity.get("type") == "Entity_LaneNode" and entity_name.begins_with(LANE[1]):
			bad.append(_position(entity))
	var paired: Array[Vector2] = []
	var lone: Array[Vector2] = []
	var used := {}
	for g in good:
		var nearest := -1
		for b in bad.size():
			if nearest < 0 or g.distance_to(bad[b]) < g.distance_to(bad[nearest]):
				nearest = b
		if nearest >= 0 and g.distance_to(bad[nearest]) < PAIR_DISTANCE:
			used[nearest] = true
			paired.append((g + bad[nearest]) * 0.5)
		else:
			lone.append(g)
	for b in bad.size():
		if not used.has(b):
			lone.append(bad[b])
	paired.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x + p.y < q.x + q.y)  # Legion (south-west) first
	# The axis runs between the outermost points where both sides of the lane are known
	_axis = (paired[-1] - paired[0]).normalized()
	_normal = Vector2(_axis.y, -_axis.x)
	_origin = (paired[0] + paired[-1]) * 0.5
	for point in paired + lone:
		_lane.append(Vector2(_along(point), _across(point)))
	_lane.sort()


func _along(point: Vector2) -> float:
	return (point - _origin).dot(_axis) / UNITS_PER_METER


func _across(point: Vector2) -> float:
	return (point - _origin).dot(_normal) / UNITS_PER_METER


## How far Caldavar's lane runs beside the straight axis, `u` meters along it.
func _lane_offset(u: float) -> float:
	if u <= _lane[0].x:
		return _lane[0].y
	for k in range(1, _lane.size()):
		if u <= _lane[k].x:
			return lerpf(_lane[k - 1].y, _lane[k].y, (u - _lane[k - 1].x) / (_lane[k].x - _lane[k - 1].x))
	return _lane[-1].y


## (x, z) meters on the map for a HoN position, lane straightened.
func _place(point: Vector2) -> Vector2:
	var u := _along(point)
	var v := _across(point)
	var offset := _lane_offset(u)
	var weight := 1.0 - smoothstep(STRAIGHTEN_NEAR, STRAIGHTEN_FAR, absf(v - offset))
	return Vector2(v - offset * weight, -u)


func _terrain(map: SceneState) -> TerrainData:
	for n in map.get_node_count():
		for p in map.get_node_property_count(n):
			if map.get_node_property_name(n, p) == &"data" and map.get_node_property_value(n, p) is TerrainData:
				return map.get_node_property_value(n, p)
	return null


func _on_tree_tiles(terrain: TerrainData, at: Vector2) -> bool:
	var corner := terrain.extent() * 0.5
	var reach := ceili(TILE_CHECK / terrain.cell_size)
	var center := Vector2i(((at + corner) / terrain.cell_size).round())
	for x in range(center.x - reach, center.x + reach + 1):
		for z in range(center.y - reach, center.y + reach + 1):
			if x < 0 or z < 0 or x > terrain.size.x or z > terrain.size.y:
				continue
			var vertex := Vector2(x, z) * terrain.cell_size - corner
			if vertex.distance_to(at) <= TILE_CHECK and not TREE_TILES.has(terrain.tiles[terrain.index(x, z)]):
				return false
	return true


## (x, z, radius) around the map's props and markers.
func _clearings(map: SceneState) -> Array[Vector3]:
	var list: Array[Vector3] = []
	for n in range(1, map.get_node_count()):
		var node_name := String(map.get_node_name(n))
		var parent := String(map.get_node_path(n, true)).trim_prefix("./")  # ".", "Props", ...
		if not CLEAR_PARENTS.has(parent) or node_name.ends_with("Forest"):
			continue
		var place := Transform3D.IDENTITY
		var placed := false
		for p in map.get_node_property_count(n):
			if map.get_node_property_name(n, p) == &"transform":
				place = map.get_node_property_value(n, p)
				placed = true
		if placed or CLEAR_RADIUS_BY_NAME.has(node_name):
			list.append(Vector3(place.origin.x, place.origin.z, CLEAR_RADIUS_BY_NAME.get(node_name, CLEAR_RADIUS)))
	return list


## The model's widest reach from the middle of its bounds, seen from above, as MapProp measures
## its footprint (meters, unscaled).
func _model_radius(model: String) -> float:
	var node: Node3D = (load("%s/%s/%s.glb" % [TREES, model, model]) as PackedScene).instantiate()
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


func _write_scene(trees: Array[Dictionary], path: String) -> Dictionary:
	var models: Array[String] = []
	for tree in trees:
		if not models.has(tree.model):
			models.append(tree.model)
	models.sort()
	var radius := {}
	# Keep the scene's uid when writing it again, so maps that instance it keep finding it
	var uid := ResourceUID.id_to_text(ResourceUID.create_id())
	if FileAccess.file_exists(path):
		var header := FileAccess.open(path, FileAccess.READ).get_line()
		var found := RegEx.create_from_string("uid=\"(uid://[a-z0-9]+)\"").search(header)
		if found != null:
			uid = found.get_string(1)
	var lines: Array[String] = ["[gd_scene format=3 uid=\"%s\"]" % uid, ""]
	lines.append(_ext("Script", "res://scripts/map/map_prop_batch.gd", "batch"))
	lines.append(_ext("Script", "res://scripts/map/map_prop.gd", "prop"))
	for model in models:
		radius[model] = _model_radius(model)
		lines.append(_ext("PackedScene", "%s/%s/%s.glb" % [TREES, model, model], model))
	lines += ["", "[node name=\"%sForest\" type=\"Node3D\"]" % MAP.capitalize(), "script = ExtResource(\"batch\")"]
	trees.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.at.y < b.at.y or (a.at.y == b.at.y and a.at.x < b.at.x))
	var counts := {}
	for tree in trees:
		var index: int = counts.get(tree.model, 0)
		counts[tree.model] = index + 1
		var scale: float = tree.scale
		var basis := Basis(Vector3.UP, tree.yaw).scaled(Vector3(scale, scale, scale))
		var reach: float = radius[tree.model] * scale
		var values := PackedStringArray()
		for row in 3:  # a scene file writes the basis row by row: x.x, y.x, z.x, x.y, ...
			for column in [basis.x, basis.y, basis.z]:
				values.append(String.num(column[row], 6))
		lines += ["",
				"[node name=\"%s#%d\" parent=\".\" instance=ExtResource(\"%s\")]" % [tree.model, index, tree.model],
				"transform = Transform3D(%s, %.4f, 0, %.4f)" % [", ".join(values), tree.at.x, tree.at.y],
				"script = ExtResource(\"prop\")",
				"footprint = 2",
				"footprint_scale = %.3f" % (minf(BLOCKER_RADIUS, reach * 0.6) / reach),
				"see_through_scale = %.1f" % SEE_THROUGH_SCALE,
				"metadata/_edit_group_ = true"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	return counts


func _ext(type: String, path: String, id: String) -> String:
	var uid := ResourceLoader.get_resource_uid(path)
	var uid_text := " uid=\"%s\"" % ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else ""
	return "[ext_resource type=\"%s\"%s path=\"%s\" id=\"%s\"]" % [type, uid_text, path, id]


## Walks a grid out from the lane's middle: how much open ground the trees cut off, and which
## clearings can't be reached.
@warning_ignore_start("integer_division")
func _check(trees: Array[Dictionary], clearings: Array[Vector3], half: Vector2, preview: String) -> void:
	var size := Vector2i((half * 2.0 / GRID).ceil())
	var blocked := PackedByteArray()
	blocked.resize(size.x * size.y)
	var r := BLOCKER_RADIUS + AGENT_RADIUS
	var reach := ceili(r / GRID)
	for tree in trees:
		var at: Vector2 = tree.at
		var cell := Vector2i(((at + half) / GRID).floor())
		for x in range(maxi(cell.x - reach, 0), mini(cell.x + reach + 1, size.x)):
			for z in range(maxi(cell.y - reach, 0), mini(cell.y + reach + 1, size.y)):
				if (Vector2(x + 0.5, z + 0.5) * GRID - half).distance_to(at) < r:
					blocked[z * size.x + x] = 1
	var seen := PackedByteArray()
	seen.resize(size.x * size.y)
	var start := (size.y / 2) * size.x + size.x / 2
	var queue := PackedInt32Array([start])
	seen[start] = 1
	var head := 0
	while head < queue.size():
		var at := queue[head]
		head += 1
		var x := at % size.x
		var z := at / size.x
		for next in [at - 1 if x > 0 else -1, at + 1 if x < size.x - 1 else -1, at - size.x if z > 0 else -1, at + size.x if z < size.y - 1 else -1]:
			if next >= 0 and not seen[next] and not blocked[next]:
				seen[next] = 1
				queue.append(next)
	var cut_off := 0
	for k in blocked.size():
		if not blocked[k] and not seen[k]:
			cut_off += 1
	var unreachable: Array[String] = []
	for c in clearings:
		var cell := Vector2i(((Vector2(c.x, c.y) + half) / GRID).floor())
		if cell.x >= 0 and cell.y >= 0 and cell.x < size.x and cell.y < size.y and not seen[cell.y * size.x + cell.x]:
			unreachable.append("(%.0f, %.0f)" % [c.x, c.y])
	print("cut off from the lane: %.0f m2 of open ground; clearings: %s" % [cut_off * GRID * GRID,
			", ".join(unreachable) if not unreachable.is_empty() else "all reachable"])
	if preview.is_empty():
		return
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGB8)
	for k in blocked.size():
		image.set_pixel(k % size.x, k / size.x, Color8(28, 70, 32) if blocked[k] else (Color8(52, 60, 44) if seen[k] else Color8(150, 40, 40)))
	for c in clearings:
		for step in 64:
			var p := (Vector2(c.x, c.y) + Vector2.from_angle(TAU * step / 64.0) * c.z + half) / GRID
			if p.x >= 0 and p.y >= 0 and p.x < size.x and p.y < size.y:
				image.set_pixelv(Vector2i(p), Color8(230, 200, 60))
	for z in size.y:
		image.set_pixel(size.x / 2, z, Color8(200, 200, 200))
	image.save_png(preview)
@warning_ignore_restore("integer_division")


func _join(counts: Dictionary) -> String:
	var parts := PackedStringArray()
	for key: String in counts:
		parts.append("%s %d" % [key, counts[key]])
	return ", ".join(parts)
