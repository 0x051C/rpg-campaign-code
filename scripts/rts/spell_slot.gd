class_name SpellSlot
extends Control

## One button of the spell panel, drawn the way noh's UpdateActiveInventory feeds its
## ability slots: icon, hotkey, level pips, mana cost, cooldown sweep and timer, plus
## the "can't use", low mana, targeting, autocast and "can level up" states.
## Left click casts, right click toggles autocast, the + badge learns a level.
## Slots from Unit.HERO_ABILITY_SLOTS on show the abilities of the unit's items.

signal activated(slot: int)
signal autocast_toggled(slot: int)
signal learn_pressed(slot: int)

const SIZE := Vector2(64.0, 64.0)
const BADGE_RADIUS := 9.0
const BORDER := Color(0.55, 0.55, 0.6)
const TARGETING_BORDER := Color(1.0, 0.9, 0.3)
const AUTOCAST_BORDER := Color(1.0, 0.75, 0.2)
const LEARN_BADGE := Color(0.3, 0.85, 0.35)
const MANA_TEXT := Color(0.55, 0.7, 1.0)

var slot := 0
var hotkey := ""
var unit: Unit
var targeting := false


func _init(side := SIZE.x) -> void:
	custom_minimum_size = Vector2(side, side)
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP


func _process(_delta: float) -> void:
	queue_redraw()


func ability() -> AbilityDefinition:
	return unit.ability_at(slot) if unit != null else null


func _gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed or ability() == null:
		return
	if event.button_index == MOUSE_BUTTON_LEFT:
		if unit.can_learn(slot) and event.position.distance_to(_badge_center()) <= BADGE_RADIUS + 3.0:
			learn_pressed.emit(slot)
		else:
			activated.emit(slot)
		accept_event()
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		autocast_toggled.emit(slot)
		accept_event()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	var spell := ability()
	if spell == null:
		draw_rect(rect, Color(0.08, 0.08, 0.1, 0.8))
		draw_rect(rect, BORDER * Color(1, 1, 1, 0.4), false, 1.0)
		return
	var level := unit.ability_level(slot)
	var font := get_theme_default_font()
	var scale_factor := size.x / SIZE.x

	# Icon
	var cooldown := unit.cooldown_fraction(slot) if level > 0 else 0.0
	if spell.icon != null:
		draw_texture_rect(spell.icon, rect, false, Color(0.7, 0.7, 0.7) if spell.is_passive() else Color.WHITE)
	else:
		var base := spell.icon_color.darkened(0.45 if spell.is_passive() else 0.2)
		draw_rect(rect, base)
		draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.45)), spell.icon_color.lightened(0.15) * Color(1, 1, 1, 0.35))
		if cooldown <= 0.0:
			_draw_centered(font, spell.icon_glyph, rect.get_center() + Vector2(0, 9) * scale_factor, roundi(24 * scale_factor), Color.WHITE)

	# States
	if level < 1:
		draw_rect(rect, Color(0.05, 0.05, 0.05, 0.65))
	elif not spell.is_passive() and unit.mana < unit.mana_cost(slot):
		draw_rect(rect, Color(0.1, 0.25, 0.9, 0.4))
	if cooldown > 0.0:
		_draw_sweep(rect, cooldown)
		_draw_centered(font, "%d" % ceili(unit.ability_cooldown(slot)), rect.get_center() + Vector2(0, 8) * scale_factor, roundi(20 * scale_factor), Color.WHITE)

	# Border: targeting, autocast or plain
	if targeting:
		draw_rect(rect, TARGETING_BORDER, false, 3.0)
	elif unit.is_autocast(slot):
		_draw_autocast_border(rect)
	else:
		draw_rect(rect, BORDER, false, 1.0)

	# Hotkey, mana cost, level pips
	if not spell.is_passive():
		_draw_text(font, hotkey, Vector2(4, 14), 13, Color.WHITE)
		var cost := unit.mana_cost(slot)
		if cost > 0.0:
			var text := "%d" % cost
			_draw_text(font, text, Vector2(size.x - font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x - 4, size.y - 4), 12, MANA_TEXT)
	for pip in (spell.max_level if slot < Unit.HERO_ABILITY_SLOTS else 0):
		var pip_rect := Rect2(4 + pip * 7, size.y - 9, 5, 5)
		draw_rect(pip_rect, Color(1.0, 0.85, 0.3) if pip < level else Color(0, 0, 0, 0.6))
		draw_rect(pip_rect, Color(0, 0, 0, 0.8), false, 1.0)

	if unit.can_learn(slot):
		draw_circle(_badge_center(), BADGE_RADIUS, LEARN_BADGE)
		_draw_centered(font, "+", _badge_center() + Vector2(0, 6), 16, Color.WHITE)


func _badge_center() -> Vector2:
	return Vector2(size.x - BADGE_RADIUS - 2.0, BADGE_RADIUS + 2.0)


## Dark pie from twelve o'clock, clockwise, covering what is left of the cooldown.
func _draw_sweep(rect: Rect2, fraction: float) -> void:
	var center := rect.get_center()
	var reach := rect.size.length()
	var points := PackedVector2Array([center])
	var steps := 32
	for i in steps + 1:
		var angle := -PI * 0.5 + TAU * (1.0 - fraction) + TAU * fraction * i / steps
		points.append(center + Vector2(cos(angle), sin(angle)) * reach)
	var clipped := Geometry2D.intersect_polygons(points, PackedVector2Array([
		rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]))
	for polygon in clipped:
		draw_colored_polygon(polygon, Color(0, 0, 0, 0.62))


func _draw_autocast_border(rect: Rect2) -> void:
	var phase := fmod(Time.get_ticks_msec() / 400.0, 1.0)
	var perimeter := (rect.size.x + rect.size.y) * 2.0
	var dashes := 10
	for i in dashes:
		var t := fmod((i + phase) / dashes, 1.0) * perimeter
		draw_circle(_perimeter_point(rect, t), 2.5, AUTOCAST_BORDER)
	draw_rect(rect, AUTOCAST_BORDER * Color(1, 1, 1, 0.5), false, 1.0)


static func _perimeter_point(rect: Rect2, distance: float) -> Vector2:
	var w := rect.size.x
	var h := rect.size.y
	if distance < w:
		return rect.position + Vector2(distance, 0)
	if distance < w + h:
		return rect.position + Vector2(w, distance - w)
	if distance < 2.0 * w + h:
		return rect.position + Vector2(w - (distance - w - h), h)
	return rect.position + Vector2(0, h - (distance - 2.0 * w - h))


func _draw_text(font: Font, text: String, at: Vector2, font_size: int, color: Color) -> void:
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color.BLACK)
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _draw_centered(font: Font, text: String, baseline_center: Vector2, font_size: int, color: Color) -> void:
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	_draw_text(font, text, baseline_center - Vector2(width * 0.5, 0), font_size, color)
