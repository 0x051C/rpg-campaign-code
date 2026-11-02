@tool
class_name TerrainTileset
extends Resource

## The ground types a Terrain is painted with. A tile's index in `tiles` is what the
## terrain stores per vertex, so reordering tiles repaints maps that use the tileset.

const MAX_TILES := 16  ## terrain.gdshader's tile_meters array

@export var tiles: Array[TerrainTile] = []:
	set(value):
		for tile in tiles:
			if tile != null and tile.changed.is_connected(emit_changed):
				tile.changed.disconnect(emit_changed)
		tiles = value
		for tile in tiles:
			if tile != null:
				tile.changed.connect(emit_changed)
		emit_changed()
## Every tile's textures are resized to this square size to share the shader's texture arrays.
@export_enum("256:256", "512:512", "1024:1024", "2048:2048") var texture_size := 1024:
	set(value):
		texture_size = value
		emit_changed()


## The albedo and height texture arrays the terrain shader samples, one layer per tile.
func build_arrays() -> Array[Texture2DArray]:
	var albedos: Array[Image] = []
	var heights: Array[Image] = []
	for tile in tiles:
		albedos.append(_layer(tile.albedo if tile != null else null, Image.FORMAT_RGBA8, Color.MAGENTA))
		heights.append(_layer(tile.height if tile != null else null, Image.FORMAT_L8, Color(0.5, 0.5, 0.5)))
	if albedos.is_empty():
		albedos.append(_layer(null, Image.FORMAT_RGBA8, Color(0.3, 0.5, 0.25)))
		heights.append(_layer(null, Image.FORMAT_L8, Color(0.5, 0.5, 0.5)))
	var albedo_array := Texture2DArray.new()
	albedo_array.create_from_images(albedos)
	var height_array := Texture2DArray.new()
	height_array.create_from_images(heights)
	return [albedo_array, height_array]


func tile_meters() -> PackedFloat32Array:
	var meters := PackedFloat32Array()
	meters.resize(MAX_TILES)
	meters.fill(4.0)
	for i in mini(tiles.size(), MAX_TILES):
		if tiles[i] != null:
			meters[i] = tiles[i].texture_meters
	return meters


func is_walkable(tile: int) -> bool:
	return tile >= tiles.size() or tiles[tile] == null or tiles[tile].walkable


func _layer(texture: Texture2D, format: Image.Format, fallback: Color) -> Image:
	var image: Image
	if texture == null:
		image = Image.create(texture_size, texture_size, false, format)
		image.fill(fallback)
	else:
		image = texture.get_image()
		if image.is_compressed():
			image.decompress()
		image.clear_mipmaps()
		image.convert(format)
		if image.get_size() != Vector2i(texture_size, texture_size):
			image.resize(texture_size, texture_size, Image.INTERPOLATE_LANCZOS)
	image.generate_mipmaps()
	return image
