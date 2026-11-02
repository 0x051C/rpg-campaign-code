class_name TargetingIndicator
extends RefCounted

## What a spell draws while the player aims it. Every frame of a targeting state the
## overlay hands one to AbilityDefinition.draw_targeting, which spells override to
## draw their own markers (noh: the tool's target material and proxy sprites drawn
## by CClientCommander::Frame). Positions are world space, drawn onto the ground.

const RANGE_COLOR := Color(0.55, 0.75, 1.0, 0.35)
const AREA_COLOR := Color(0.55, 0.85, 1.0, 0.9)
const VALID_COLOR := Color(0.4, 1.0, 0.45, 0.95)
const INVALID_COLOR := Color(1.0, 0.35, 0.3, 0.95)
const SEGMENTS := 48

## The ground point under the cursor.
var cursor := Vector3.ZERO
## The unit under the cursor, or UnitRegistry.NONE.
var hover := UnitRegistry.NONE

var _canvas: CanvasItem
var _view: Camera3D
var _registry: UnitRegistry


func _init(canvas: CanvasItem, view: Camera3D, registry: UnitRegistry) -> void:
	_canvas = canvas
	_view = view
	_registry = registry


func circle(center: Vector3, radius: float, color := AREA_COLOR, width := 2.0) -> void:
	var points := PackedVector2Array()
	for i in SEGMENTS + 1:
		var angle := TAU * i / SEGMENTS
		var point := Terrain.lift(center + Vector3(cos(angle) * radius, 0.1, sin(angle) * radius))
		if _view.is_position_behind(point):
			return
		points.append(_view.unproject_position(point))
	_canvas.draw_polyline(points, color, width, true)


func line(from: Vector3, to: Vector3, color := AREA_COLOR, width := 2.0) -> void:
	var points := PackedVector2Array()
	for point in Terrain.ground_path(from + Vector3.UP * 0.1, to + Vector3.UP * 0.1):
		if _view.is_position_behind(point):
			return
		points.append(_view.unproject_position(point))
	_canvas.draw_polyline(points, color, width, true)


## A ring around a unit's feet, sized to the unit.
func unit_ring(handle: int, color := VALID_COLOR, width := 2.5) -> void:
	if _registry.is_alive(handle):
		circle(_registry.position_of(handle), _registry.radius_of(handle) + 0.35, color, width)


## Text over a unit's head, at its scaled height.
func unit_label(handle: int, text: String, color := Color.WHITE, font_size := 16) -> void:
	if _registry.is_alive(handle):
		label(_registry.position_of(handle) + Vector3.UP * (_registry.height_of(handle) + 0.6), text, color, font_size)


## Text floating at a gameplay point (lifted onto the terrain), e.g. the heal a spell would do.
func label(at: Vector3, text: String, color := Color.WHITE, font_size := 16) -> void:
	at = Terrain.lift(at)
	if _view.is_position_behind(at):
		return
	var font := ThemeDB.fallback_font
	var at_screen := _view.unproject_position(at)
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	at_screen.x -= width * 0.5
	_canvas.draw_string_outline(font, at_screen, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 4, Color.BLACK)
	_canvas.draw_string(font, at_screen, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
