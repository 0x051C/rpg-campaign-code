extends RefCounted

## The layout of a big story map, Dead Cells' way (DIRECTION.md 5; Sébastien Benard, "Building the
## Level Design of a procedurally generated Metroidvania"): the story fixes the places and their
## order, the plan decides where they go.
##
## The map is a grid of CELL-sized cells (the outer ring left to the rim). A main road winds across it
## in a general direction (north: from the bottom edge to the top; or south, east, west), one cell at a
## time, onwards or sideways but never back, so it never crosses itself; the story's stops (an array
## of nodes) are spread along it in order, the start first and the goal last. Branches leave it from a
## stop with stops of their own (an old blind off the hunters' camp). Side places sit in free cells
## next to a road. What's left near the road is filler, for
## pieces (woods, graves, ruins, camps) placed by the map's own rules; `progress()` says how far along
## the road a cell is, for monsters that get worse towards the goal.
##
## The same seed gives the same map: a story map is the same on every run and every load.

const CELL := 24.0

var size: Vector2i
var cols := 0
var rows := 0
var rng := RandomNumberGenerator.new()
var road: Array[Vector2i] = []  ## cells, start to goal
var places: Dictionary[String, Vector3] = {}  ## name -> where (a cell's middle, nudged)
var cells: Dictionary[Vector2i, String] = {}  ## taken cells -> "road", or the place's name
var branches: Array[Array] = []  ## each branch's cells (Array[Vector2i]), from the road outwards
var direction := "north"  ## where the main road heads (lay_road)

## Direction -> how a cell of the plan laid northwards turns to face it (the grid is square).
const TURNS := {"north": 0, "east": 1, "south": 2, "west": 3}


func _init(map_size: Vector2i, seed: int) -> void:
	size = map_size
	cols = int(map_size.x / CELL)
	rows = int(map_size.y / CELL)
	rng.seed = seed


## Winds the main road across the map towards `heading` (north, south, east or west) and sets `stops`
## along it, the first at the start and the last at the goal. It's laid northwards, then turned.
func lay_road(stops: Array[String], heading := "north") -> void:
	assert(cols == rows, "AreaPlan turns its roads on square maps only")
	direction = heading
	var at := Vector2i(cols / 2 + rng.randi_range(-1, 1), rows - 2)
	var goal_column := rng.randi_range(1, cols - 2)
	road = [at]
	var sideways := 0
	var min_length := stops.size() * 2
	while at.y > 1 or at.x != goal_column:
		var options: Array[Vector2i] = []
		var weights: Array[float] = []
		if at.y > 1:
			options.append(at + Vector2i(0, -1))
			# Climb more slowly while the road is still short for its stops
			weights.append(1.0 if road.size() < min_length else 3.0)
		for dx in [-1, 1]:
			var side := at + Vector2i(dx, 0)
			if side.x < 1 or side.x > cols - 2 or road.has(side):
				continue
			if at.y == 1:
				if signi(goal_column - at.x) == dx:
					options.append(side)
					weights.append(5.0)  # on the top row: straight for the goal
				continue
			if sideways < 2:
				options.append(side)
				weights.append(2.0 if signi(goal_column - at.x) == dx else 1.0)
		var pick := rng.rand_weighted(PackedFloat32Array(weights))
		var next := options[pick]
		sideways = sideways + 1 if next.y == at.y else 0
		at = next
		road.append(at)
	var turns: int = TURNS.get(heading, 0)
	for i in road.size():
		road[i] = _turn(road[i], turns)
	for cell in road:
		cells[cell] = "road"
	for i in stops.size():
		var index := 0 if i == 0 else (road.size() - 1 if i == stops.size() - 1 else
				int(round(float(i) / (stops.size() - 1) * (road.size() - 1))))
		_put(stops[i], road[index], 0.0)


## A branch road from the stop `from` into free cells, `length` cells long at most, with `stops` along
## it (the last at its end). Returns false if there was no room for it.
func add_branch(from: String, stops: Array[String], length := 3) -> bool:
	var at := cell_of(from)
	var branch: Array[Vector2i] = []
	var heading := Vector2i.ZERO
	for step in length:
		var options: Array[Vector2i] = []
		var weights := PackedFloat32Array()
		for offset: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next := at + offset
			if not _inside(next) or cells.has(next) or branch.has(next):
				continue
			if step == 0 and _road_distance_excluding(next, at) <= 0:
				continue
			options.append(next)
			weights.append(3.0 if offset == heading else 1.0)  # mostly straight on
		if options.is_empty():
			break
		var next := options[rng.rand_weighted(weights)]
		heading = next - at
		at = next
		branch.append(at)
	if branch.size() < stops.size():
		return false
	for cell in branch:
		cells[cell] = "road"
	branches.append(branch)
	for i in stops.size():
		var index := branch.size() - 1 if i == stops.size() - 1 else int(round(float(i + 1) / stops.size() * (branch.size() - 1)))
		_put(stops[i], branch[index], 0.0)
	return true


## A cell turned `turns` quarter turns clockwise about the grid's middle (north to east, ...).
func _turn(cell: Vector2i, turns: int) -> Vector2i:
	var turned := cell
	for i in turns:
		turned = Vector2i(rows - 1 - turned.y, turned.x)
	return turned


## A place off the road: a free cell next to it, away from the start and the goal.
func add_side(place_name: String) -> Vector3:
	var choices: Array[Vector2i] = []
	for i in range(2, road.size() - 2):
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var cell: Vector2i = road[i] + offset
			if _inside(cell) and not cells.has(cell) and not choices.has(cell):
				choices.append(cell)
	if choices.is_empty():
		return Vector3.INF
	var cell := choices[rng.randi_range(0, choices.size() - 1)]
	_put(place_name, cell, 3.0)
	return places[place_name]


## The free cells within `reach` cells of the road: room for pieces.
func filler(reach := 2) -> Array[Vector2i]:
	var free: Array[Vector2i] = []
	for z in range(1, rows - 1):
		for x in range(1, cols - 1):
			var cell := Vector2i(x, z)
			if not cells.has(cell) and _road_distance(cell) <= reach:
				free.append(cell)
	return free


## The free cells farther than `reach` from the road: wilderness, for scenery.
func wild(reach := 2) -> Array[Vector2i]:
	var far: Array[Vector2i] = []
	for z in range(1, rows - 1):
		for x in range(1, cols - 1):
			var cell := Vector2i(x, z)
			if not cells.has(cell) and _road_distance(cell) > reach:
				far.append(cell)
	return far


## How far along the road a cell lies: 0 at the start, 1 at the goal (the nearest road cell's share).
func progress(cell: Vector2i) -> float:
	var best := 0
	var best_distance := 1 << 30
	for i in road.size():
		var distance := absi(road[i].x - cell.x) + absi(road[i].y - cell.y)
		if distance < best_distance:
			best_distance = distance
			best = i
	return float(best) / maxf(road.size() - 1, 1)


## The middle of a cell in the map's coordinates (the map's middle at 0, 0).
func world(cell: Vector2i) -> Vector3:
	return Vector3((cell.x + 0.5) * CELL - size.x * 0.5, 0.0, (cell.y + 0.5) * CELL - size.y * 0.5)


## The road as points for the terrain (Vector2 x, z): through every road cell's middle, a little
## nudged so it doesn't run ruler-straight, from just past the edge it comes in by to its goal.
func road_points() -> Array:
	var points := []
	var first := world(road[0])
	var edge: Vector2 = {"north": Vector2(first.x, size.y * 0.5), "south": Vector2(first.x, -size.y * 0.5),
			"east": Vector2(-size.x * 0.5, first.z), "west": Vector2(size.x * 0.5, first.z)}[direction]
	points.append(edge)
	for i in road.size():
		var at := world(road[i])
		var nudge := Vector2.ZERO if i == 0 or i == road.size() - 1 else Vector2(rng.randf_range(-4, 4), rng.randf_range(-4, 4))
		points.append(Vector2(at.x, at.z) + nudge)
	return points


## Each branch as points for the terrain, from the road cell it leaves.
func branch_points() -> Array:
	var all := []
	for branch in branches:
		var start := (branch[0] as Vector2i)
		var points := []
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if road.has(start + offset):
				var from := world(start + offset)
				points.append(Vector2(from.x, from.z))
				break
		for cell: Vector2i in branch:
			var at := world(cell)
			points.append(Vector2(at.x, at.z))
		all.append(points)
	return all


func cell_of(place_name: String) -> Vector2i:
	var at := places[place_name]
	return Vector2i(int((at.x + size.x * 0.5) / CELL), int((at.z + size.y * 0.5) / CELL))


func _put(place_name: String, cell: Vector2i, nudge: float) -> void:
	cells[cell] = place_name
	places[place_name] = world(cell) + Vector3(rng.randf_range(-nudge, nudge), 0.0, rng.randf_range(-nudge, nudge))


func _inside(cell: Vector2i) -> bool:
	return cell.x >= 1 and cell.y >= 1 and cell.x <= cols - 2 and cell.y <= rows - 2


func _road_distance(cell: Vector2i) -> int:
	var best := 1 << 30
	for road_cell in road:
		best = mini(best, absi(road_cell.x - cell.x) + absi(road_cell.y - cell.y))
	for branch in branches:
		for branch_cell: Vector2i in branch:
			best = mini(best, absi(branch_cell.x - cell.x) + absi(branch_cell.y - cell.y))
	return best


## How far `cell` is from the main road, not counting the road cell `except` (where a branch leaves).
func _road_distance_excluding(cell: Vector2i, except: Vector2i) -> int:
	var best := 1 << 30
	for road_cell in road:
		if road_cell != except:
			best = mini(best, absi(road_cell.x - cell.x) + absi(road_cell.y - cell.y))
	return best
