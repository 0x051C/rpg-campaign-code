class_name WalkGrid
extends RefCounted

## The walkable ground of a map's navigation mesh as a grid of bytes, CELL meters square: a cell
## is walkable when its middle lies in one of the mesh's polygons. Built once when the map bakes
## its navigation (main.gd), for the checks units make every tick: NavigationServer3D's
## closest-point query looks through every polygon (0.35 ms per call on Caldavar's 12,000),
## a lookup here is one byte.
##
## step() keeps a moving unit on walkable ground, sliding along walls. Where the grid can't
## tell (both slides blocked: a corner, or a passage narrower than a cell) it answers INF and
## the caller asks the NavigationServer as before.

const CELL := 0.5

static var current: WalkGrid  ## the running map's; null before its navigation is baked

var origin := Vector2.ZERO  ## world XZ of the first cell's corner
var size := Vector2i.ZERO
var cells := PackedByteArray()  ## 1: walkable, row by row along +Z


## Rasterizes the (convex) polygons of `mesh`, placed by `placement`, row by row.
static func from_navigation_mesh(mesh: NavigationMesh, placement: Transform3D) -> WalkGrid:
	var grid := WalkGrid.new()
	var vertices := mesh.get_vertices()
	if vertices.is_empty():
		return grid
	var flat := PackedVector2Array()
	flat.resize(vertices.size())
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for i in vertices.size():
		var world := placement * vertices[i]
		flat[i] = Vector2(world.x, world.z)
		low = low.min(flat[i])
		high = high.max(flat[i])
	grid.origin = (low / CELL).floor() * CELL
	grid.size = Vector2i(((high - grid.origin) / CELL).ceil()) + Vector2i.ONE
	grid.cells.resize(grid.size.x * grid.size.y)
	for p in mesh.get_polygon_count():
		var polygon := mesh.get_polygon(p)
		var top := INF
		var bottom := -INF
		for index in polygon:
			top = minf(top, flat[index].y)
			bottom = maxf(bottom, flat[index].y)
		# Rows whose middle line crosses the polygon: the span between its edges there
		for row in range(maxi(ceili((top - grid.origin.y) / CELL - 0.5), 0), mini(floori((bottom - grid.origin.y) / CELL - 0.5), grid.size.y - 1) + 1):
			var z := grid.origin.y + (row + 0.5) * CELL
			var left := INF
			var right := -INF
			for k in polygon.size():
				var a := flat[polygon[k]]
				var b := flat[polygon[(k + 1) % polygon.size()]]
				if (a.y <= z and b.y >= z) or (b.y <= z and a.y >= z):
					var x := a.x if is_equal_approx(a.y, b.y) else a.x + (b.x - a.x) * (z - a.y) / (b.y - a.y)
					left = minf(left, x)
					right = maxf(right, x)
			var first := maxi(ceili((left - grid.origin.x) / CELL - 0.5), 0)
			var last := mini(floori((right - grid.origin.x) / CELL - 0.5), grid.size.x - 1)
			for column in range(first, last + 1):
				grid.cells[row * grid.size.x + column] = 1
	return grid


func is_walkable(at: Vector3) -> bool:
	var column := floori((at.x - origin.x) / CELL)
	var row := floori((at.z - origin.y) / CELL)
	return column >= 0 and row >= 0 and column < size.x and row < size.y and cells[row * size.x + column] == 1


## Where a unit at `from` heading for `to` (one tick's move) ends up: `to` on walkable ground,
## else sliding along the wall on one axis; INF when neither works (ask the NavigationServer).
func step(from: Vector3, to: Vector3) -> Vector3:
	if is_walkable(to):
		return to
	var along_x := Vector3(to.x, to.y, from.z)
	if is_walkable(along_x):
		return along_x
	var along_z := Vector3(from.x, to.y, to.z)
	if is_walkable(along_z):
		return along_z
	return Vector3.INF


## The middle of the walkable cell nearest to `at` within `reach` meters, or INF.
func nearest_walkable(at: Vector3, reach := 6.0) -> Vector3:
	if is_walkable(at):
		return at
	var center := Vector2i(floori((at.x - origin.x) / CELL), floori((at.z - origin.y) / CELL))
	var best := Vector3.INF
	var best_distance := INF
	var rings := ceili(reach / CELL)
	for ring in range(1, rings + 1):
		for dz in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dz)) != ring:
					continue  # only this ring's border
				var cell := center + Vector2i(dx, dz)
				if cell.x < 0 or cell.y < 0 or cell.x >= size.x or cell.y >= size.y or cells[cell.y * size.x + cell.x] == 0:
					continue
				var middle := Vector3(origin.x + (cell.x + 0.5) * CELL, at.y, origin.y + (cell.y + 0.5) * CELL)
				var distance := Vector2(middle.x - at.x, middle.z - at.z).length_squared()
				if distance < best_distance:
					best_distance = distance
					best = middle
		if best != Vector3.INF:
			return best  # the nearest ring with any: close enough
	return best
