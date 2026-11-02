class_name Tutorial
extends CanvasLayer

## Teaches the controls without a lesson plan: its TutorialLesson children are quiet hints, one
## line above the bottom HUD, that show only when the player seems stuck and fade out as soon as
## they do the thing. Everything the player does on their own is remembered (Campaign flags),
## so the hints they don't need never show: the best tutorial is the one you don't notice.
##
## Killing `cut_short_by` (an NPC, e.g. the prologue's ledger) ends the hints for good, on
## every map.

## A hint showed up.
signal hint_shown(lesson: TutorialLesson)
## No more hints: `cut_short_by` died.
signal ended

const CHECK_TIME := 0.25
const NEAR := 12.0  ## meters from a hero that count as "nearby"
const LOW_HEALTH := 0.33
const PAN_DISTANCE := 6.0  ## meters of camera travel that count as "camera_pan"
const ZOOM_CHANGE := 0.5
const PATHS_HOLD := 0.4
const BETWEEN_HINTS := 6.0  ## seconds of quiet after a hint
const FADE := 0.4
const HINT_FONT_SIZE := 15
const HINT_BOTTOM := 190.0  ## pixels above the window's bottom edge, over the HUD

## Killing this NPC ends the hints for good.
@export var cut_short_by: NeutralSpawn

var current: TutorialLesson  ## the hint showing now

var _commander: Commander
var _registry: UnitRegistry
var _camera: RTSCamera
var _party: PartyInventory
var _held: Dictionary[TutorialLesson, float] = {}  ## how long each hint's situation has lasted
var _showing := 0.0
var _quiet := 0.0
var _check := 0.0
var _camera_last := Vector3.INF
var _camera_travel := 0.0
var _zoom_last := 0.0
var _shift_time := 0.0
var _bag_size := -1
var _label := RichTextLabel.new()


func _ready() -> void:
	layer = 3
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_label.custom_minimum_size = Vector2(900, 0)
	_label.position = Vector2(-450, -HINT_BOTTOM)
	_label.add_theme_font_size_override(&"normal_font_size", HINT_FONT_SIZE)
	_label.add_theme_font_size_override(&"bold_font_size", HINT_FONT_SIZE)
	_label.add_theme_color_override(&"default_color", Color(1, 1, 1, 0.85))
	_label.add_theme_constant_override(&"outline_size", 5)
	_label.add_theme_color_override(&"font_outline_color", Color(0, 0, 0, 0.75))
	_label.modulate.a = 0.0
	add_child(_label)
	_start.call_deferred()  # after the map spawned its heroes


func lessons() -> Array[TutorialLesson]:
	var list: Array[TutorialLesson] = []
	for child in get_children():
		if child is TutorialLesson:
			list.append(child)
	return list


func is_over() -> bool:
	return _state().get("over", false)


## Whether the player has done `action` (ever, on any map).
func knows(action: StringName) -> bool:
	return _state().get("known", []).has(String(action))


## Whether the player already knows what `lesson` teaches.
func knows_lesson(lesson: TutorialLesson) -> bool:
	for action in lesson.wait_for:
		if knows(StringName(action)):
			return true
	return false


## No more hints (cut short).
func end() -> void:
	if is_over():
		return
	_save("over", true)
	_hide()
	ended.emit()


func _start() -> void:
	_party = get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	_commander = _party.commander if _party != null else null
	_registry = get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	if _commander == null or _registry == null:
		return
	_camera = _commander.camera
	_commander.acted.connect(_learned)
	_registry.unit_died.connect(_on_unit_died)
	_bag_size = _party.bag.size()


## The player did `action`: known from now on; a hint about it fades.
func _learned(action: StringName) -> void:
	var known: Array = _state().get("known", [])
	if not known.has(String(action)):
		known.append(String(action))
		_save("known", known)
	if current != null and current.wait_for.has(String(action)):
		_hide()


func _on_unit_died(handle: int, _killer: int) -> void:
	if cut_short_by != null and handle == cut_short_by.handle and handle != UnitRegistry.NONE:
		end()


func _process(delta: float) -> void:
	if _commander == null or is_over():
		return
	_watch_input(delta)
	_quiet = maxf(_quiet - delta, 0.0)
	if current != null:
		_showing += delta
		if _showing >= current.show_for:
			_hide()
	_check -= delta
	if _check > 0.0:
		return
	_check = CHECK_TIME
	var shown: Dictionary = _state().get("shown", {})
	var next: TutorialLesson = null
	for lesson in lessons():
		if knows_lesson(lesson) or shown.get(str(lesson.name), 0) >= lesson.times or not _holds(lesson.when):
			_held[lesson] = 0.0
			continue
		_held[lesson] = _held.get(lesson, 0.0) + CHECK_TIME
		if next == null and _held[lesson] >= lesson.delay:
			next = lesson
	if current == null and next != null and _quiet <= 0.0:
		_show(next)


## Things the player does that the Commander doesn't report: looking around, zooming, the
## overlay map, the inventory, saving, holding Shift.
func _watch_input(delta: float) -> void:
	if _camera != null:
		if _camera_last != Vector3.INF:
			_camera_travel += Vector2(_camera.position.x - _camera_last.x, _camera.position.z - _camera_last.z).length()
			if _camera_travel > PAN_DISTANCE:
				_learned(&"camera_pan")
				_camera_travel = -INF
			if absf(_camera.distance - _zoom_last) > ZOOM_CHANGE:
				_learned(&"zoom")
		_camera_last = _camera.position
		if absf(_camera.distance - _zoom_last) > ZOOM_CHANGE or _zoom_last == 0.0:
			_zoom_last = _camera.distance
	for pair: Array in [[&"rts_map_overlay", &"overlay"], [&"rts_inventory", &"inventory"], [&"rts_quick_save", &"quick_save"]]:
		if Input.is_action_just_pressed(pair[0]):
			_learned(pair[1])
	_shift_time = _shift_time + delta if Input.is_action_pressed(&"rts_modifier_queue") else 0.0
	if _shift_time >= PATHS_HOLD:
		_learned(&"paths")
		_shift_time = -INF


## Whether the situation a hint waits for is going on.
func _holds(when: TutorialLesson.When) -> bool:
	var heroes := _heroes()
	match when:
		TutorialLesson.When.START:
			return true
		TutorialLesson.When.NOTHING_SELECTED:
			return _commander.control_selection.is_empty()
		TutorialLesson.When.NPC_NEARBY:
			return _near(heroes, func(other: int) -> bool:
				return _registry.is_neutral(other) and _registry.dialogue_of(other) != null)
		TutorialLesson.When.ENEMY_NEARBY:
			return _near(heroes, _is_enemy)
		TutorialLesson.When.SKILL_POINT:
			return heroes.any(func(hero: Unit) -> bool:
				return range(hero.definition.abilities.size()).any(hero.can_learn))
		TutorialLesson.When.SPELL_READY:
			return _near(heroes, _is_enemy) and heroes.any(func(hero: Unit) -> bool:
				return range(hero.definition.abilities.size()).any(func(slot: int) -> bool:
					return hero.ability_at(slot) != null and not hero.ability_at(slot).is_passive() \
							and hero.ability_error(slot).is_empty()))
		TutorialLesson.When.ITEM_PICKED_UP:
			return _party.bag.size() > _bag_size
		TutorialLesson.When.OBJECTIVE:
			return get_tree().get_nodes_in_group(Quest.GROUP).any(func(quest: Node) -> bool: return (quest as Quest).is_running())
		TutorialLesson.When.LOW_HEALTH:
			return heroes.any(func(hero: Unit) -> bool:
				return hero.is_alive() and _registry.health_of(hero.handle) < _registry.max_health_of(hero.handle) * LOW_HEALTH)
		TutorialLesson.When.SECOND_HERO:
			return heroes.size() >= 2
		TutorialLesson.When.THIRD_HERO:
			return heroes.size() >= 3
	return false


func _heroes() -> Array[Unit]:
	var list: Array[Unit] = []
	for handle in _commander.heroes:
		var unit := _registry.unit_of(handle)
		if unit != null:
			list.append(unit)
	return list


func _near(heroes: Array[Unit], matches: Callable) -> bool:
	for hero in heroes:
		if not hero.is_alive():
			continue
		for other in _registry.query_radius(hero.global_position, NEAR):
			if _registry.player_sees(other) and matches.call(other):
				return true
	return false


func _is_enemy(other: int) -> bool:
	return UnitRegistry.are_enemies(_registry.team_of(other), _registry.player_team)


func _show(lesson: TutorialLesson) -> void:
	current = lesson
	_showing = 0.0
	var shown: Dictionary = _state().get("shown", {})
	shown[str(lesson.name)] = shown.get(str(lesson.name), 0) + 1
	_save("shown", shown)
	_label.text = "[center]%s[/center]" % lesson.text
	create_tween().tween_property(_label, ^"modulate:a", 1.0, FADE)
	hint_shown.emit(lesson)


func _hide() -> void:
	if current != null:
		_held[current] = 0.0
	current = null
	_quiet = BETWEEN_HINTS
	create_tween().tween_property(_label, ^"modulate:a", 0.0, FADE)


func _state() -> Dictionary:
	return Campaign.current.flags.get("tutorial", {}) if Campaign.current != null else {}


func _save(key: String, value: Variant) -> void:
	if Campaign.current != null:
		var state: Dictionary = Campaign.current.flags.get_or_add("tutorial", {})
		state[key] = value
