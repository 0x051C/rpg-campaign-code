extends SceneTree
## Terrain brush strokes: the per-edit blocked cells match a full recompute (the old
## algorithm), blockers wait for the stroke's end, and what a dab costs now.

func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	change_scene_to_file("res://scenes/maps/prologue.tscn")
	await create_timer(2.0).timeout
	var terrain := Terrain.current
	var data := terrain.data
	var failures := 0
	var obstacles_before := terrain._blockers.get_child_count()
	terrain.begin_stroke()
	var dab_time := 0
	for i in 60:
		var center := Vector2i(randi_range(5, data.size.x - 5), randi_range(5, data.size.y - 5))
		var rect := Rect2i(center - Vector2i(4, 4), Vector2i(9, 9))
		var heights := data.heights
		var tiles := data.tiles
		for z in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				heights[data.index(x, z)] += randf_range(-0.8, 0.8)
				if randf() < 0.3:
					tiles[data.index(x, z)] = randi_range(0, terrain.tileset.tiles.size() - 1)
		data.heights = heights
		data.tiles = tiles
		var t := Time.get_ticks_usec()
		terrain.commit_heights(rect)
		terrain.commit_tiles(rect)
		dab_time += Time.get_ticks_usec() - t
		await process_frame
	print("60 dabs: %.2f ms each on the main thread" % (dab_time / 60000.0))
	var held := terrain._blockers_queued == false
	terrain.end_stroke()
	print("blockers held back during the stroke: ", held)
	var reference := _reference(terrain)
	var incremental := terrain.blocked_cells()
	var differ := 0
	for i in reference.size():
		if reference[i] != incremental[i]:
			differ += 1
	print("blocked cells differing from a full recompute: %d of %d (%d blocked)" % [differ, reference.size(), reference.count(1)])
	if differ != 0 or not held:
		failures += 1
	await process_frame
	await process_frame
	print("obstacles rebuilt at stroke end: %d -> %d" % [obstacles_before, terrain._blockers.get_child_count()])
	print("FAILURES: %d" % failures)
	quit()


## The old blocked_cells, cell by cell over the whole map.
func _reference(terrain: Terrain) -> PackedByteArray:
	var data := terrain.data
	var blocked := PackedByteArray()
	blocked.resize(data.size.x * data.size.y)
	var max_rise := tan(deg_to_rad(terrain.max_walkable_slope)) * data.cell_size
	var row := data.size.x + 1
	for z in data.size.y:
		for x in data.size.x:
			var i := z * row + x
			var unwalkable := 0
			for corner: int in [i, i + 1, i + row, i + row + 1]:
				if not terrain.tileset.is_walkable(data.tiles[corner]):
					unwalkable += 1
			var h00 := data.heights[i]
			var h10 := data.heights[i + 1]
			var h01 := data.heights[i + row]
			var h11 := data.heights[i + row + 1]
			var rise := maxf(maxf(absf(h00 - h10), absf(h01 - h11)), maxf(absf(h00 - h01), absf(h10 - h11)))
			rise = maxf(rise, absf(h00 - h11) / sqrt(2.0))
			blocked[z * data.size.x + x] = 1 if unwalkable >= 2 or rise > max_rise else 0
	return blocked
