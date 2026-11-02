extends SceneTree
## Breaks a hand-built map's prop groups into presets: every cluster of placed models (props standing within
## `--radius` of each other, at the map's top level or in a plain group node like "Carriage"; never the Story,
## the HUD, the terrain or the map's machinery) becomes a scene in `--out`, centred on the cluster, named after
## its biggest member. The story generator (and you, in the editor) can drop them anywhere: MapProps that keep
## to the ground settle onto the new terrain; the others keep their height above it.
##
##   godot --headless --path . --script res://tools/presets/extract_presets.gd -- \
##       --map=res://scenes/maps/prologue.tscn --out=res://scenes/presets/prologue [--radius=7] [--min=2]
##
## It writes over presets of the same name (re-run it after changing the map); single props are left out.

const SKIPPED := ["Story", "HUD", "NavigationRegion3D", "WorldEnvironment", "RTSCamera", "FogOfWar", "UnitRegistry",
		"Corpses", "Party", "Commander", "Heroes", "SeeThrough", "Tutorial", "HeroStart"]

var _map := "res://scenes/maps/prologue.tscn"
var _out := "res://scenes/presets/prologue"
var _radius := 7.0
var _min := 2
var _root: Node


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		var value := arg.get_slice("=", 1)
		if arg.begins_with("--map="):
			_map = value
		elif arg.begins_with("--out="):
			_out = value
		elif arg.begins_with("--radius="):
			_radius = value.to_float()
		elif arg.begins_with("--min="):
			_min = value.to_int()
	var root: Node3D = (load(_map) as PackedScene).instantiate()
	_root = root
	var props := _placed(root)
	var clusters := _clusters(props)
	DirAccess.make_dir_recursive_absolute(_out)
	var written := 0
	for cluster in clusters:
		if cluster.size() < _min:
			continue
		var path := _write(cluster)
		print("%s: %d props (%s)" % [path, cluster.size(), ", ".join(cluster.map(func(n: Node3D) -> String: return n.name))])
		written += 1
	print("presets: %d from %d props" % [written, props.size()])
	root.free()
	quit()


## The models placed by hand: scene instances at the top level, or one level down in plain group nodes.
func _placed(root: Node) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for child in root.get_children():
		if SKIPPED.has(String(child.name)):
			continue
		if child is Node3D and not (child as Node).scene_file_path.is_empty():
			found.append(child)
		elif child.scene_file_path.is_empty() and child.get_script() == null:
			for inner in child.get_children():  # a group like "Carriage"
				if inner is Node3D and not inner.scene_file_path.is_empty():
					found.append(inner)
	return found


## Props within `_radius` of each other (on the ground plane), joined into clusters.
func _clusters(props: Array[Node3D]) -> Array[Array]:
	var group := range(props.size())
	var find := func(i: int, own: Callable) -> int:
		while group[i] != i:
			group[i] = group[group[i]]
			i = group[i]
		return i
	for i in props.size():
		for j in range(i + 1, props.size()):
			var a := _world(props[i]).origin
			var b := _world(props[j]).origin
			if Vector2(a.x - b.x, a.z - b.z).length() <= _radius:
				group[find.call(i, find)] = find.call(j, find)
	var by_root := {}
	for i in props.size():
		by_root.get_or_add(find.call(i, find), []).append(props[i])
	var clusters: Array[Array] = []
	for members: Array in by_root.values():
		clusters.append(members)
	return clusters


## `node`'s transform in the map (out of the tree: its own, times its Node3D parents' up to the root).
func _world(node: Node3D) -> Transform3D:
	var transform := node.transform
	var parent := node.get_parent()
	while parent != null and parent != _root:
		if parent is Node3D:
			transform = (parent as Node3D).transform * transform
		parent = parent.get_parent()
	return transform


## A preset's name: the group its props stand in (Carriage), else its biggest prop with a real name (not the
## editor's "@Node3D@123"), its number taken off.
func _name_of(cluster: Array, biggest: Node3D) -> String:
	var parent: Node = cluster[0].get_parent()
	if parent != _root and cluster.all(func(n: Node) -> bool: return n.get_parent() == parent):
		return String(parent.name).to_pascal_case()
	var named := cluster.filter(func(n: Node) -> bool: return not String(n.name).begins_with("@") and not String(n.name).begins_with("_"))
	var pick: Node = biggest if named.has(biggest) or named.is_empty() else named[0]
	return String(pick.name).rstrip("0123456789").to_pascal_case()


## Saves one cluster as a preset: positions around its centre, heights above its lowest grounded member.
func _write(cluster: Array) -> String:
	var center := Vector3.ZERO
	var ground := INF
	var biggest: Node3D = cluster[0]
	for prop: Node3D in cluster:
		center += _world(prop).origin
		if prop.get(&"keep_on_ground") != false:
			ground = minf(ground, _world(prop).origin.y)
		if _world(prop).basis.get_scale().length() > _world(biggest).basis.get_scale().length():
			biggest = prop
	center /= cluster.size()
	if ground == INF:
		ground = center.y
	var preset := Node3D.new()
	var base := _name_of(cluster, biggest)
	preset.name = base
	for prop: Node3D in cluster:
		var copy := prop.duplicate() as Node3D
		var world := _world(prop)
		copy.transform = Transform3D(world.basis, world.origin - Vector3(center.x, ground, center.z))
		preset.add_child(copy)
		copy.owner = preset
	var path := "%s/%s.tscn" % [_out, base.to_snake_case()]
	var packed := PackedScene.new()
	packed.pack(preset)
	ResourceSaver.save(packed, path)
	preset.free()
	return path
