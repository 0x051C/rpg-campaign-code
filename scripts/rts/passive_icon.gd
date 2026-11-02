class_name PassiveIcon
extends Control

## A round icon on the item bar: the class info icon, the attack type, or a running buff
## (gold ring). Round, so it doesn't read as a button that casts something; the spell panel
## fills in the tooltip. Clicking emits `pressed` (the info icon opens the character window).

signal pressed

const BORDER := Color(0.55, 0.55, 0.6)

var glyph := ""
var color := Color.GRAY
var count := 0  ## a number in the corner when above 0, e.g. the attacks Reflection has left
var ring_color := BORDER


func _init(side: float) -> void:
	custom_minimum_size = Vector2(side, side)
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP


func show_icon(icon_glyph: String, icon_color: Color, icon_count := 0) -> void:
	if glyph != icon_glyph or color != icon_color or count != icon_count:
		glyph = icon_glyph
		color = icon_color
		count = icon_count
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		pressed.emit()
		accept_event()


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - 1.0
	draw_circle(center, radius, color.darkened(0.35))
	draw_circle(center - Vector2(0, radius * 0.25), radius * 0.7, color.lightened(0.15) * Color(1, 1, 1, 0.25))
	draw_arc(center, radius, 0.0, TAU, 32, ring_color, 1.5, true)
	var font := get_theme_default_font()
	var font_size := roundi(radius * 0.8)
	var width := font.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var at := center + Vector2(-width * 0.5, font_size * 0.35)
	draw_string_outline(font, at, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color.BLACK)
	draw_string(font, at, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)
	if count > 0:
		var number := str(count)
		var small := roundi(radius * 0.95)
		var corner := Vector2(size.x - font.get_string_size(number, HORIZONTAL_ALIGNMENT_LEFT, -1, small).x, size.y)
		draw_string_outline(font, corner, number, HORIZONTAL_ALIGNMENT_LEFT, -1, small, 4, Color.BLACK)
		draw_string(font, corner, number, HORIZONTAL_ALIGNMENT_LEFT, -1, small, Color(1.0, 0.85, 0.35))
