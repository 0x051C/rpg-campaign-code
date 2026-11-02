class_name ItemCell
extends Control

## One square of the inventory window: an item (its glyph and color, like a spell icon)
## or an empty slot showing what goes there. Drag it onto another cell or the bag to move
## the item; right-click is the window's shortcut.

const BORDER := Color(0.55, 0.55, 0.6)
const DROP_BORDER := Color(1.0, 0.9, 0.3)

var window: InventoryWindow
var place: PartyInventory.Place
var item: ItemDefinition:
	set(value):
		item = value
		queue_redraw()
var caption := ""  ## shown in the empty slot
var _drop_hover := false


func _init(side: float) -> void:
	custom_minimum_size = Vector2(side, side)
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(func() -> void:
		if window != null:
			window.hover_cell(self))
	mouse_exited.connect(func() -> void:
		_drop_hover = false
		queue_redraw()
		if window != null:
			window.unhover_cell(self))


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _drop_hover:
		_drop_hover = false
		queue_redraw()


func _get_drag_data(_at_position: Vector2) -> Variant:
	if item == null or window == null:
		return null
	var preview := ItemCell.new(size.x)
	preview.item = item
	preview.modulate.a = 0.8
	set_drag_preview(preview)
	return place


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	var ok := window != null and data is PartyInventory.Place and window.can_drop(data, place)
	if ok != _drop_hover:
		_drop_hover = ok
		queue_redraw()
	return ok


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	_drop_hover = false
	window.drop(data, place)


func _gui_input(event: InputEvent) -> void:
	if window != null and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		window.quick_move(place)
		accept_event()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	var font := get_theme_default_font()
	if item == null:
		draw_rect(rect, Color(0.08, 0.08, 0.1, 0.85))
		if not caption.is_empty():
			var font_size := 10
			var width := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			draw_string(font, Vector2((size.x - width) * 0.5, size.y * 0.5 + 4), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 1, 1, 0.35))
	else:
		draw_rect(rect, item.icon_color.darkened(0.25))
		draw_rect(Rect2(rect.position, Vector2(rect.size.x, rect.size.y * 0.45)), item.icon_color.lightened(0.15) * Color(1, 1, 1, 0.35))
		var font_size := roundi(size.x * 0.36)
		var width := font.get_string_size(item.icon_glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var at := Vector2((size.x - width) * 0.5, size.y * 0.5 + font_size * 0.35)
		draw_string_outline(font, at, item.icon_glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color.BLACK)
		draw_string(font, at, item.icon_glyph, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)
		if item.ability != null:
			draw_circle(Vector2(size.x - 6, 6), 3.5, Color(0.55, 0.75, 1.0))  # has an ability
	if item != null and item.rarity != ItemDefinition.Rarity.COMMON and not _drop_hover:
		draw_rect(rect, item.name_color(), false, 2.0)  # a magic or rare item's frame in its color
	else:
		draw_rect(rect, DROP_BORDER if _drop_hover else BORDER, false, 2.0 if _drop_hover else 1.0)
