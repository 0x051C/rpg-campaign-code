@tool
class_name TerrainData
extends Resource

## A terrain's heights and tile ids, one of each per grid vertex: (size.x + 1) x (size.y + 1)
## values, row by row along +Z. Save it as a binary .res next to its map.

@export var size := Vector2i(64, 64)  ## cells
@export var cell_size := 1.0  ## meters
@export var heights := PackedFloat32Array()
@export var tiles := PackedByteArray()
## Cells units can't walk on whatever their tile and slope, one byte each (size.x x size.y,
## row by row), 1 = blocked: an imported map's pathing (tools/noh/noh_map.gd). Empty: none.
@export var blockers := PackedByteArray()
## A color multiplied over the painted ground, RGB bytes per grid vertex like `heights`, e.g.
## an imported map's vertex colors. Empty: none.
@export var tint := PackedByteArray()

@export_group("Heightmap file")
## An image the heights follow, to paint them in an image editor (Map Editor: Terrain dock >
## Heightmap > Link): save it there and the editor reloads it; sculpting here writes it back
## when the scene is saved. A 16-bit grayscale PNG (black = heightmap_low m, white =
## heightmap_high m) or an .exr in meters. The game uses `heights`, not the file.
@export_file("*.png", "*.exr") var heightmap := ""
@export var heightmap_low := 0.0
@export var heightmap_high := 20.0
## The file's modification time and the heights' hash at the last read or write.
@export var heightmap_time := 0
@export var heightmap_hash := 0


static func create(cells: Vector2i, meters_per_cell := 1.0, tile := 0) -> TerrainData:
	var data := TerrainData.new()
	data.size = cells
	data.cell_size = meters_per_cell
	var count := (cells.x + 1) * (cells.y + 1)
	data.heights.resize(count)
	data.heights.fill(0.0)
	data.tiles.resize(count)
	data.tiles.fill(tile)
	return data


func vertices() -> Vector2i:
	return size + Vector2i.ONE


func extent() -> Vector2:
	return Vector2(size) * cell_size


func index(x: int, z: int) -> int:
	return z * (size.x + 1) + x


func is_valid() -> bool:
	var count := (size.x + 1) * (size.y + 1)
	return size.x > 0 and size.y > 0 and heights.size() == count and tiles.size() == count
