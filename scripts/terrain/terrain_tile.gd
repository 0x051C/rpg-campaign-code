@tool
class_name TerrainTile
extends Resource

## One paintable ground type of a TerrainTileset (grass, dirt, cobblestone...).

@export var name := "Tile":
	set(value):
		name = value
		emit_changed()
## Seamless color texture.
@export var albedo: Texture2D:
	set(value):
		albedo = value
		emit_changed()
## Seamless grayscale height, bright = raised. Where tiles meet, the higher texels win, so
## stones poke through grass instead of a plain crossfade. Optional (flat without it).
@export var height: Texture2D:
	set(value):
		height = value
		emit_changed()
## Meters covered by one repeat of the textures.
@export var texture_meters := 4.0:
	set(value):
		texture_meters = maxf(value, 0.01)
		emit_changed()
## Off for water, lava, chasms: the navigation mesh leaves cells painted with it out.
@export var walkable := true:
	set(value):
		walkable = value
		emit_changed()
## Small objects and foliage strewn over this tile (see GraphicsSettings.scatter_quality).
@export var scatter: Array[ScatterItem] = []:
	set(value):
		for item in scatter:
			if item != null and item.changed.is_connected(emit_changed):
				item.changed.disconnect(emit_changed)
		scatter = value
		for item in scatter:
			if item != null:
				item.changed.connect(emit_changed)
		emit_changed()
