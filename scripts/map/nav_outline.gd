@tool
class_name NavOutline
extends RefCounted

## The shape of a baked navigation mesh: the edges where walking stops and which
## polygons connect, used by the Map Editor's preview and by the overlay map.

const QUANTUM := 0.02  ## corners closer than this are the same point

var polygon_count := 0
## Pockets of walkable area units can't reach from the largest one.
var island_count := 0
## Line segment pairs along the walkable area's edges.
var border := PackedVector3Array()
## Per polygon, whether it belongs to the largest connected walkable area.
var reachable := PackedByteArray()

var _groups := PackedInt32Array()  ## union-find over polygons


static func of(navigation_mesh: NavigationMesh) -> NavOutline:
	var outline := NavOutline.new()
	outline._analyze(navigation_mesh)
	return outline


func _analyze(navigation_mesh: NavigationMesh) -> void:
	var vertices := navigation_mesh.get_vertices()
	polygon_count = navigation_mesh.get_polygon_count()

	# Baked polygons don't always share vertex indices, so match corners by position
	var point_ids := PackedInt32Array()
	var ids_by_point: Dictionary[Vector3i, int] = {}
	for vertex in vertices:
		var key := Vector3i((vertex / QUANTUM).round())
		if not ids_by_point.has(key):
			ids_by_point[key] = ids_by_point.size()
		point_ids.append(ids_by_point[key])

	# Polygons sharing an edge are connected; an edge used once is a border
	_groups.resize(polygon_count)
	for i in polygon_count:
		_groups[i] = i
	var edge_users: Dictionary[Vector2i, int] = {}
	var edge_polygon: Dictionary[Vector2i, int] = {}
	for p in polygon_count:
		var polygon := navigation_mesh.get_polygon(p)
		for i in polygon.size():
			var a := point_ids[polygon[i]]
			var b := point_ids[polygon[(i + 1) % polygon.size()]]
			var key := Vector2i(mini(a, b), maxi(a, b))
			if edge_users.has(key):
				edge_users[key] += 1
				_groups[_find(p)] = _find(edge_polygon[key])
			else:
				edge_users[key] = 1
				edge_polygon[key] = p

	for p in polygon_count:
		var polygon := navigation_mesh.get_polygon(p)
		for i in polygon.size():
			var a := polygon[i]
			var b := polygon[(i + 1) % polygon.size()]
			if edge_users[Vector2i(mini(point_ids[a], point_ids[b]), maxi(point_ids[a], point_ids[b]))] == 1:
				border.append_array([vertices[a], vertices[b]])

	# The group with the most area is where the units live; the rest are islands
	var areas: Dictionary[int, float] = {}
	for p in polygon_count:
		var group := _find(p)
		areas[group] = areas.get(group, 0.0) + _area(vertices, navigation_mesh.get_polygon(p))
	var main_group := -1
	for group in areas:
		if main_group < 0 or areas[group] > areas[main_group]:
			main_group = group
	island_count = maxi(areas.size() - 1, 0)
	reachable.resize(polygon_count)
	for p in polygon_count:
		reachable[p] = 1 if _find(p) == main_group else 0


func _find(index: int) -> int:
	while _groups[index] != index:
		_groups[index] = _groups[_groups[index]]
		index = _groups[index]
	return index


static func _area(vertices: PackedVector3Array, polygon: PackedInt32Array) -> float:
	var area := 0.0
	for i in range(1, polygon.size() - 1):
		area += (vertices[polygon[i]] - vertices[polygon[0]]).cross(vertices[polygon[i + 1]] - vertices[polygon[0]]).length() * 0.5
	return area
