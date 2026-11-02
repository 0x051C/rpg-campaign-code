@tool
class_name ScatterItem
extends Resource

## Small things a TerrainTile is strewn with: a tiny mesh (pebbles, twigs, mushrooms) or a
## foliage billboard (grass tufts, flowers), drawn many times over cells painted with the tile.
## Purely visual: units walk through them and the navigation mesh ignores them.

## A mesh with its own material. Leave empty and set `billboard` for foliage.
@export var mesh: Mesh:
	set(value):
		mesh = value
		emit_changed()
## A foliage sprite (alpha cut-out), drawn upright and turning toward the camera.
@export var billboard: Texture2D:
	set(value):
		billboard = value
		emit_changed()
## Billboard width and height in meters at scale 1, standing on the ground.
@export var billboard_size := Vector2(0.6, 0.5):
	set(value):
		billboard_size = value
		emit_changed()
## Instances per square meter at the highest scatter quality.
@export_range(0.0, 20.0, 0.01) var density := 1.0:
	set(value):
		density = value
		emit_changed()
## Random scale between x and y.
@export var scale_range := Vector2(0.8, 1.2):
	set(value):
		scale_range = value
		emit_changed()
## 0 stands upright, 1 leans with the slope.
@export_range(0.0, 1.0) var align_to_ground := 0.0:
	set(value):
		align_to_ground = value
		emit_changed()
## Pushes meshes into the ground (meters), so rounded stones don't float.
@export var sink := 0.0:
	set(value):
		sink = value
		emit_changed()
## Random darkening/tinting, 0 for none.
@export_range(0.0, 1.0) var color_variation := 0.2:
	set(value):
		color_variation = value
		emit_changed()
## Lowest scatter quality that draws this item at all.
@export var min_quality := GraphicsSettings.Quality.LOW:
	set(value):
		min_quality = value
		emit_changed()
## Not drawn beyond this distance from the camera (meters).
@export var max_distance := 60.0:
	set(value):
		max_distance = value
		emit_changed()
@export var cast_shadow := false:
	set(value):
		cast_shadow = value
		emit_changed()
