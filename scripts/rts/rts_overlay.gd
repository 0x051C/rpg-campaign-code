class_name RTSOverlay
extends Control

## Screen-space commander feedback: the drag-selection box (noh CClientCommander::Draw),
## health bars for every living row of the UnitRegistry (plus mana for heroes and the
## timed life of summons), the order or spell being targeted next to the cursor with
## its range and area circles, refused-action messages (noh ErrorMessage), and, while
## the queue modifier is held, the queued waypoints and walking paths of the selection.

const BOX_FILL := Color(0.3, 0.7, 1.0, 0.2)
const BOX_BORDER := Color.WHITE
const BAR_HEIGHT := 5.0
const REVIVE_COLOR := Color(1.0, 0.85, 0.3)
const BAR_BACKGROUND := Color(0.0, 0.0, 0.0, 0.75)
const MANA_COLOR := Color(0.35, 0.55, 1.0)
const LIFETIME_COLOR := Color(0.9, 0.9, 0.9)
const PATH_COLOR := Color(1.0, 1.0, 1.0, 0.35)
const ERROR_COLOR := Color(1.0, 0.85, 0.3)
const STATE_HINTS: Dictionary[Commander.State, String] = {
	Commander.State.MOVE: "Move",
	Commander.State.ATTACK: "Attack",
	Commander.State.PATROL: "Patrol",
}

@export var commander: Commander


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var view := get_viewport().get_camera_3d()
	if view == null:
		return
	_draw_targeting(view)
	_draw_health_bars(view)
	_draw_item_name(view)
	if Input.is_action_pressed(&"rts_modifier_queue"):
		_draw_waypoints(view)
	if commander.is_drag_selecting():
		var rect := commander.get_selection_rect()
		draw_rect(rect, BOX_FILL)
		draw_rect(rect, BOX_BORDER, false, 1.0)
	_draw_hint()
	_draw_error()


func _draw_hint() -> void:
	var text := ""
	var color := Color.WHITE
	if STATE_HINTS.has(commander.state):
		text = STATE_HINTS[commander.state]
		if commander.state == Commander.State.ATTACK:
			color = Commander.COLOR_ENEMY
	elif commander.get_targeting_ability() != null:
		text = commander.get_targeting_ability().display_name
		color = Commander.COLOR_SPELL
	if not text.is_empty():
		draw_string(get_theme_default_font(), commander.cursor_position + Vector2(18.0, 30.0),
			text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 15, color)


func _draw_error() -> void:
	var left := commander.error_until - Time.get_ticks_msec()
	if left <= 0 or commander.error_text.is_empty():
		return
	var font := get_theme_default_font()
	var alpha := clampf(left / 500.0, 0.0, 1.0)
	var text_size := font.get_string_size(commander.error_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18)
	var at := Vector2((get_rect().size.x - text_size.x) * 0.5, get_rect().size.y - 190.0)
	draw_string_outline(font, at, commander.error_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18, 4, Color(0, 0, 0, alpha))
	var color := commander.error_color if commander.error_color.a > 0.0 else ERROR_COLOR
	draw_string(font, at, commander.error_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18, Color(color, alpha))


## The spell being aimed draws its own markers (AbilityDefinition.draw_targeting).
func _draw_targeting(view: Camera3D) -> void:
	var ability := commander.get_targeting_ability()
	var caster := commander.get_caster()
	if ability == null or caster == null:
		return
	var spell := SpellCast.new()
	spell.ability = ability
	spell.level = maxi(caster.ability_level(commander.active_slot), 1)
	spell.caster = caster
	spell.registry = commander.registry
	spell.target = commander.hover
	spell.point = commander.trace_position
	var indicator := TargetingIndicator.new(self, view, commander.registry)
	indicator.cursor = commander.trace_position
	indicator.hover = commander.hover
	ability.draw_targeting(indicator, spell)


func _draw_health_bars(view: Camera3D) -> void:
	var registry := commander.registry
	for handle in registry.handles(UnitRegistry.Kind.HERO, true):
		_draw_revive_bar(view, registry, handle)  # fallen heroes
	for kind in UnitRegistry.KINDS:
		var ids := registry.handles(kind)
		var positions := registry.display_positions(kind)  # with the models, between ticks
		var heights := registry.float_column(kind, "look.height")
		var healths := registry.float_column(kind, "health")
		var max_healths := registry.float_column(kind, "max_health")
		var teams := registry.int_column(kind, "team")
		var sighted := registry.int_column(kind, "sighted")
		for i in ids.size():
			if not UnitRegistry.sees_bits(registry.player_team, teams[i], sighted[i]):
				continue
			var head := Terrain.lift(positions[i]) + Vector3.UP * (heights[i] + 0.4)
			if view.is_position_behind(head):
				continue
			var center := view.unproject_position(head)
			if not get_rect().has_point(center):
				continue
			var width := 48.0 if kind == UnitRegistry.Kind.HERO else 30.0
			var bar := Rect2(center.x - width * 0.5, center.y, width, BAR_HEIGHT)
			_draw_bar(bar, healths[i] / max_healths[i] if max_healths[i] > 0.0 else 0.0, registry.relation_color(ids[i]))
			var unit := registry.unit_of(ids[i])
			if unit == null:
				continue
			bar.position.y += BAR_HEIGHT + 2.0
			bar.size.y = 3.0
			if unit.is_summon():
				_draw_bar(bar, unit.lifetime_left / unit.lifetime, LIFETIME_COLOR)
			elif unit.max_mana > 0.0:
				_draw_bar(bar, unit.mana / unit.max_mana, MANA_COLOR)


## The name of the item under the cursor, over it, in its color (Diablo style).
func _draw_item_name(view: Camera3D) -> void:
	var item := commander.hover_item
	if item == null or not is_instance_valid(item):
		return
	var spot := item.global_position + Vector3.UP * 0.6
	if view.is_position_behind(spot):
		return
	var font := get_theme_default_font()
	var text := item.display_name()
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	var at := view.unproject_position(spot) - Vector2(width * 0.5, 0.0)
	draw_rect(Rect2(at + Vector2(-6, -16), Vector2(width + 12, 22)), Color(0, 0, 0, 0.6))
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 3, Color.BLACK)
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, item.name_color())


## A fallen hero being revived: a gold bar over the body, filling up.
func _draw_revive_bar(view: Camera3D, registry: UnitRegistry, handle: int) -> void:
	var unit := registry.unit_of(handle)
	if unit == null or unit.revive_progress() <= 0.0:
		return
	var spot := Terrain.lift(registry.position_of(handle)) + Vector3.UP * 1.2
	if view.is_position_behind(spot):
		return
	var center := view.unproject_position(spot)
	var bar := Rect2(center.x - 30.0, center.y, 60.0, BAR_HEIGHT + 2.0)
	_draw_bar(bar, unit.revive_progress(), REVIVE_COLOR)
	var font := get_theme_default_font()
	draw_string_outline(font, bar.position + Vector2(0, -3), "Reviving", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color.BLACK)
	draw_string(font, bar.position + Vector2(0, -3), "Reviving", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, REVIVE_COLOR)


func _draw_bar(bar: Rect2, fraction: float, color: Color) -> void:
	draw_rect(bar.grow(1.0), BAR_BACKGROUND)
	bar.size.x *= clampf(fraction, 0.0, 1.0)
	draw_rect(bar, color)


## Queued orders as lines, plus the path each unit is actually walking.
func _draw_waypoints(view: Camera3D) -> void:
	var registry := commander.registry
	for handle in commander.control_selection:
		var unit := registry.unit_of(handle)
		var path := unit._agent.get_current_navigation_path()
		for i in range(unit._agent.get_current_navigation_path_index(), path.size() - 1):
			_draw_world_line(view, path[i], path[i + 1], PATH_COLOR, false)
		var from := unit.global_position
		for order in unit.orders:
			if order.type == UnitOrder.Type.HOLD:
				continue
			var to := order.get_world_position(registry)
			var color := _order_color(order.type)
			_draw_world_line(view, from, to, color)
			if order.type == UnitOrder.Type.PATROL:
				_draw_world_line(view, to, order.patrol_origin, Color(color, 0.4))
			from = to


func _draw_world_line(view: Camera3D, from: Vector3, to: Vector3, color: Color, dot := true) -> void:
	var points := PackedVector2Array()
	for point in Terrain.ground_path(from + Vector3.UP * 0.1, to + Vector3.UP * 0.1):
		if view.is_position_behind(point):
			return
		points.append(view.unproject_position(point))
	draw_polyline(points, color, 1.5, true)
	if dot:
		draw_circle(points[-1], 3.0, color)


static func _order_color(type: UnitOrder.Type) -> Color:
	match type:
		UnitOrder.Type.ATTACK, UnitOrder.Type.ATTACK_MOVE:
			return Commander.COLOR_ENEMY
		UnitOrder.Type.PATROL:
			return Commander.COLOR_PATROL
		UnitOrder.Type.CAST:
			return Commander.COLOR_SPELL
	return Commander.COLOR_OWN
