class_name Formation
extends RefCounted

## DotaCraft's grid unit formation (MoveUnitsInGrid in vscripts/orders.lua): a group
## move fans out into one grid block per FormationRank, rank 0 at the clicked point
## and higher ranks in rows behind it, facing the direction of travel. Each grid
## spot goes to the closest unit still without one.

const SPACING := 150.0 / RTSCamera.NOH_UNITS_PER_METER  ## UNIT_FORMATION_DISTANCE
const SPACING_LARGE := 400.0 / RTSCamera.NOH_UNITS_PER_METER  ## UNIT_FORMATION_DISTANCE_LARGE
const MAX_RANK := 5  ## ancients, which take the large spacing


## Destination for every unit, aligned with `units`.
static func destinations(units: Array[Unit], point: Vector3) -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.resize(units.size())
	if units.is_empty():
		return result

	var forward := point - units[0].global_position
	forward.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	var right := forward.cross(Vector3.UP)

	# Each rank gets its own block; the widest block sets the row length for all
	var ranks: Array[Array] = []
	var max_columns := 0
	for rank in MAX_RANK + 1:
		var members: Array[int] = []
		for i in units.size():
			if clampi(units[i].definition.formation_rank, 0, MAX_RANK) == rank:
				members.append(i)
		ranks.append(members)
		if not members.is_empty():
			max_columns = maxi(max_columns, _rows_and_columns(members.size(), units.size()).y)

	var used_rows := 0
	for rank in ranks.size():
		var members: Array[int] = ranks[rank]
		if members.is_empty():
			continue
		var offset_x := SPACING
		var offset_y := SPACING
		var center := point - forward * SPACING * used_rows
		if rank == MAX_RANK:
			offset_x = SPACING_LARGE
			offset_y = SPACING_LARGE
			center -= forward * SPACING_LARGE / 3.0

		if members.size() == 1:
			result[members[0]] = center
			used_rows += 1
			continue

		var shape := _rows_and_columns_for_max(members.size(), units.size(), max_columns)
		var rows := shape.x
		var columns := shape.y
		# Stretch narrower blocks to the full row length of the group
		var row_length := offset_x * (max_columns - 1)
		if columns != max_columns and columns > 1:
			offset_x *= row_length / (offset_x * (columns - 1))
		var remainder := members.size() - rows * columns
		var remainder_factor := 1.0
		if remainder > 1:
			remainder_factor = row_length / (offset_x * (remainder - 1))

		var spots: Array[Vector3] = []
		var row_y := 0.0
		for row in rows:
			for column in columns:
				spots.append(center + right * (column - (columns - 1) * 0.5) * offset_x + forward * row_y * offset_y)
			row_y -= 1.0
		var remainder_x := offset_x * remainder_factor
		for column in remainder:
			spots.append(center + right * (column - (remainder - 1) * 0.5) * remainder_x + forward * row_y * offset_y)
		if remainder > 0:
			used_rows += 1

		# Hand out the spots, closest unit first
		var unassigned := members.duplicate()
		for spot in spots:
			var closest := -1
			var closest_distance := INF
			for i in unassigned:
				var distance := units[i].global_position.distance_squared_to(spot)
				if distance < closest_distance:
					closest_distance = distance
					closest = i
			if closest < 0:
				break
			result[closest] = spot
			unassigned.erase(closest)
		used_rows += rows
	return result


## DotaCraft GetRowsAndColumns, special cases included.
static func _rows_and_columns(count: int, total: int) -> Vector2i:
	if count == 4 and total > 4:
		return Vector2i(1, 4)
	if count == 5:
		return Vector2i(1, 3)
	if count == 7:
		return Vector2i(2, 3)
	if count == 10 or count == 1:
		return Vector2i(2, 4)
	var square_factor := 1.3 if count > 12 else 1.0
	var rows := maxi(1, floori(sqrt(count / square_factor)))
	return Vector2i(rows, floori(float(count) / rows))


## DotaCraft GetRowsAndColumnsForMaxColumns
static func _rows_and_columns_for_max(count: int, total: int, max_columns: int) -> Vector2i:
	if max_columns <= 4:
		return _rows_and_columns(count, total)
	return Vector2i(maxi(1, floori(sqrt(count / 1.3))), mini(count, max_columns))
