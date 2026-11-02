class_name Commander
extends Node

## Player input for units, ported from noh's CClientCommander
## (src/hon_client/c_clientcommander.cpp) and its binds in game_client_actions.cpp:
## cursor picking, click and box selection, smart right-click orders, targeted order
## states (attack / move / patrol), spell targeting (ActivateTool / Cast), control
## groups and the active unit of a multi-unit selection. Group moves spread out in
## DotaCraft's grid formation (vscripts/orders.lua).
##
## Selections hold UnitRegistry handles, like noh's sets of entity indices. Units you
## can order (heroes, summons) go into the control selection; anything else you click
## goes into the info selection. Orders always go to the control selection, spells to
## the active unit.

## Something the player just did, for the Tutorial: "move", "attack", "attack_move",
## "patrol", "follow", "talk", "queue", "stop", "hold", "cancel", "select", "box_select",
## "select_type", "group_saved", "group_recalled", "group_added", "group_removed",
## "hero_hotkey", "next_hero", "center", "aim", "cast", "learn", "autocast".
signal acted(action: StringName)
## A hero joined the party (add_hero, e.g. a recruited NeutralSpawn).
signal hero_joined(unit: Unit)

enum State {
	HOVER,
	SELECT,
	MOVE,
	ATTACK,
	PATROL,
	TARGET_UNIT,  ## noh COMSTATE_TARGET_ENTITY
	TARGET_POINT,  ## noh COMSTATE_TARGET_AREA
	TARGET_DUAL,  ## noh COMSTATE_TARGET_DUAL: a unit or, failing that, the ground
}
enum Order { AUTO, MOVE, ATTACK, FOLLOW, PATROL, TALK }  ## noh ECommanderOrder subset, plus talking to neutrals


class SelectionSet:
	var handles: Array[int] = []
	var focus := UnitRegistry.NONE


const NONE := UnitRegistry.NONE
const DOUBLE_SELECT_TIME_MS := 500  ## cg_cmdrDoubleSelectTime
const DOUBLE_SELECT_RADIUS := 800.0 / RTSCamera.NOH_UNITS_PER_METER  ## cg_cmdrDoubleSelectRadius
const MAX_SAVED_SELECTION_SETS := 10
const ABILITY_SLOTS := Unit.HERO_ABILITY_SLOTS
const ERROR_TIME_MS := 2200
const PICK_ITEM_PIXELS := 28.0  ## how close the cursor must be to an item on the ground
const COLOR_OWN := Color(0.3, 1.0, 0.35)
const COLOR_ALLY := Color(0.35, 0.7, 1.0)
const COLOR_ENEMY := Color(1.0, 0.25, 0.2)
const COLOR_NEUTRAL := Color(0.95, 0.8, 0.35)
const COLOR_PATROL := Color(1.0, 0.85, 0.25)
const COLOR_SPELL := Color(0.55, 0.75, 1.0)

@export var camera: RTSCamera
@export var registry: UnitRegistry

## Hero handles in hotkey order (F1-F3).
var heroes: Array[int] = []
## Last cursor position seen in a mouse event, in viewport coordinates.
var cursor_position := Vector2.ZERO
var state := State.HOVER
var hover := NONE
var trace_position := Vector3.ZERO
var control_selection: Array[int] = []
var info_selection: Array[int] = []
var hover_selection: Array[int] = []
## The item on the ground under the cursor when no unit is (its name and ring show).
var hover_item: ItemPickup
var active := NONE
## Ability slot being targeted (noh m_iActiveSlot), -1 when none.
var active_slot := -1
## The last refused action (noh ErrorMessage), shown for a moment by the overlay.
var error_text := ""
var error_color := Color(0, 0, 0, 0)  ## transparent: the overlay's error color
var error_until := 0

var _control_selection_mode := true
var _start_cursor := Vector2.ZERO
var _first := NONE
var _select_time := 0
var _last_primary_time := 0
var _last_select_time := 0
var _last_set_control_time := 0
var _last_set_control := NONE
var _last_recall_index := -1
var _last_recall_time := 0
var _saved_sets: Array[SelectionSet] = []
var _cursor_shape := Input.CURSOR_ARROW


func _ready() -> void:
	for i in MAX_SAVED_SELECTION_SETS:
		_saved_sets.append(SelectionSet.new())


func _process(_delta: float) -> void:
	_update_cursor_trace(cursor_position)
	if get_viewport().gui_get_hovered_control() != null:
		hover = NONE
		hover_item = null
	if hover_item != null:
		hover_item.mark_hovered()
	_update_hover_selection()
	_validate_selections()
	_validate_targeting()
	_update_center_binds()
	_update_cursor()
	_update_highlights()


func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		cursor_position = event.position
	# Releases are caught here so a box drag that ends over the HUD still applies
	if state == State.SELECT and event.is_action_released(&"rts_primary"):
		primary_up()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.is_action_pressed(&"rts_primary"):
			primary_down(event.position)
		elif event.is_action_pressed(&"rts_secondary"):
			secondary_down(event.position)
		else:
			return
		get_viewport().set_input_as_handled()
		return

	if not event is InputEventKey or not event.is_pressed() or event.is_echo():
		return
	var queue_modifier := Input.is_action_pressed(&"rts_modifier_queue")
	var ctrl_modifier := Input.is_action_pressed(&"rts_modifier_ctrl")

	if event.is_action_pressed(&"rts_cancel"):
		if not cancel():
			Campaign.current.open_menu()  # nothing to cancel: the game menu
	elif event.is_action_pressed(&"rts_order_attack"):
		_set_order_state(State.ATTACK)
	elif event.is_action_pressed(&"rts_order_move"):
		_set_order_state(State.MOVE)
	elif event.is_action_pressed(&"rts_order_patrol"):
		_set_order_state(State.PATROL)
	elif event.is_action_pressed(&"rts_order_stop"):
		order_stop()
	elif event.is_action_pressed(&"rts_order_hold"):
		order_hold()
	elif event.is_action_pressed(&"rts_next_unit"):
		cycle_unit(-1 if queue_modifier else 1, ctrl_modifier)
	elif event.is_action_pressed(&"rts_hero_1"):
		select_hero(0)
		acted.emit(&"hero_hotkey")  # here, not in select_hero: maps select the first hero at startup
	elif event.is_action_pressed(&"rts_hero_2"):
		select_hero(1)
		acted.emit(&"hero_hotkey")
	elif event.is_action_pressed(&"rts_hero_3"):
		select_hero(2)
		acted.emit(&"hero_hotkey")
	else:
		var ability := _pressed_index(event, "rts_ability_%d", ABILITY_SLOTS, 1)
		if ability >= 0:
			if ctrl_modifier:
				learn_ability(ability)
			else:
				activate_ability(ability)
			get_viewport().set_input_as_handled()
			return
		var item_ability := _pressed_index(event, "rts_item_%d", Unit.ITEM_ABILITY_SLOTS, 1)
		if item_ability >= 0:
			activate_ability(Unit.HERO_ABILITY_SLOTS + item_ability)
			get_viewport().set_input_as_handled()
			return
		var group := _pressed_index(event, "rts_group_%d", MAX_SAVED_SELECTION_SETS, 0)
		if group < 0:
			return
		if ctrl_modifier and queue_modifier:
			remove_from_selection_set(group)
		elif ctrl_modifier:
			save_selection_set(group)
		elif queue_modifier:
			add_to_selection_set(group)
		else:
			recall_selection_set(group)
	get_viewport().set_input_as_handled()


# --- Mouse actions (noh PrimaryDown / PrimaryUp / SecondaryDown) ----------------

func primary_down(screen_position: Vector2) -> void:
	# Clicking through the active unit lets A-click / M-click target the ground under it
	if state == State.ATTACK or state == State.MOVE:
		_update_cursor_trace(screen_position, get_selected_control())
	else:
		_update_cursor_trace(screen_position)

	match state:
		State.HOVER:
			_start_select(screen_position)
		State.MOVE:
			_start_command(trace_position, _queue(), Order.MOVE)
		State.ATTACK:
			_start_command(trace_position, _queue(), Order.ATTACK)
		State.PATROL:
			_start_command(trace_position, _queue(), Order.PATROL)
		State.TARGET_UNIT, State.TARGET_POINT, State.TARGET_DUAL:
			_cast(hover, trace_position)


## A click on a unit's button in the selection panel while aiming: casts the aimed spell
## at it, or gives the aimed attack/move/patrol order on it. False when nothing is aimed.
func aim_at_unit(handle: int) -> bool:
	if not registry.is_alive(handle):
		return false
	match state:
		State.TARGET_UNIT, State.TARGET_DUAL:
			_cast(handle, registry.position_of(handle))
		State.TARGET_POINT:
			_cast(NONE, registry.position_of(handle))
		State.ATTACK:
			give_order_unit(Order.ATTACK, handle, _queue())
			_set_order_state(State.HOVER)
		State.MOVE:
			give_order_unit(Order.FOLLOW, handle, _queue())
			_set_order_state(State.HOVER)
		State.PATROL:
			give_order_unit(Order.PATROL, handle, _queue())
			_set_order_state(State.HOVER)
		_:
			return false
	return true


func primary_up() -> void:
	if state == State.SELECT:
		_apply_select()


func secondary_down(screen_position: Vector2) -> void:
	# Right-clicking ignores the active unit so you can't order a unit onto itself
	_update_cursor_trace(screen_position, get_selected_control())
	match state:
		State.HOVER:
			if hover_item != null:
				order_pickup(hover_item, _queue())
			else:
				_start_command(trace_position, _queue())
		State.SELECT:
			cancel()
			_start_command(trace_position, _queue())
		_:
			_leave_targeting()


## Smart-click on an item: the nearest selected hero walks over and picks it up (one hero,
## not the whole selection, like talking to an NPC).
func order_pickup(item: ItemPickup, queue: Unit.Queue) -> void:
	var nearest: Unit = null
	for unit in _order_recipients():
		if unit.is_summon() or not unit.is_alive():
			continue
		if nearest == null or unit.global_position.distance_to(item.ground_spot()) < nearest.global_position.distance_to(item.ground_spot()):
			nearest = unit
	if nearest == null:
		show_error("Only heroes can pick things up")
		return
	nearest.order_pickup(item, queue)
	item.mark_targeted()


## The visible item on the ground closest to a screen point, within PICK_ITEM_PIXELS.
func _pick_item(view: Camera3D, screen_point: Vector2) -> ItemPickup:
	var best: ItemPickup = null
	var best_distance := PICK_ITEM_PIXELS
	for node in get_tree().get_nodes_in_group(ItemPickup.PICKUP_GROUP):
		var item := node as ItemPickup
		if item == null or item.is_queued_for_deletion() or not FogOfWar.player_sees(item.global_position):
			continue
		var spot := item.global_position + Vector3.UP * 0.2
		if not view.is_position_in_frustum(spot):
			continue
		var distance := view.unproject_position(spot).distance_to(screen_point)
		if distance < best_distance:
			best_distance = distance
			best = item
	return best


## noh Cancel: leaves a targeting state first, then clears the info selection.
func cancel() -> bool:
	if state != State.HOVER:
		_leave_targeting()
		acted.emit(&"cancel")
		return true
	if not info_selection.is_empty():
		info_selection.clear()
		return true
	return false


func show_error(text: String) -> void:
	show_message(text, Color(0, 0, 0, 0))
	Sounds.error()


## Shows `text` where errors show, in `color` (e.g. picking up an item).
func show_message(text: String, color: Color) -> void:
	error_text = text
	error_color = color
	error_until = Time.get_ticks_msec() + ERROR_TIME_MS


# --- Spells (noh ActivateTool / Cast / LevelupAbility) -------------------------

## The unit whose spells the HUD shows and the hotkeys cast: the active unit.
func get_caster() -> Unit:
	var caster := get_selected_control()
	return registry.unit_of(caster) if caster != NONE else null


## The ability being targeted, or null.
func get_targeting_ability() -> AbilityDefinition:
	var caster := get_caster()
	if caster == null or active_slot < 0:
		return null
	return caster.ability_at(active_slot)


## noh ActivateTool: no-target spells cast at once, the rest enter a targeting state.
func activate_ability(slot: int) -> void:
	var caster := get_caster()
	if caster == null or caster.ability_at(slot) == null:
		return
	var error := caster.ability_error(slot)
	if not error.is_empty():
		show_error(error)
		if caster.ability_level(slot) > 0 and (caster.ability_cooldown(slot) > 0.0 or caster.mana < caster.mana_cost(slot)):
			caster.say(&"refuse")
		return
	var ability := caster.ability_at(slot)
	match ability.action:
		AbilityDefinition.Action.NO_TARGET:
			caster.order_cast(slot, NONE, caster.global_position, _queue())
			acted.emit(&"cast")
			return
		AbilityDefinition.Action.TARGET_UNIT, AbilityDefinition.Action.ATTACK:
			_enter_targeting(State.TARGET_UNIT, slot)
		AbilityDefinition.Action.TARGET_POINT:
			_enter_targeting(State.TARGET_POINT, slot)
		AbilityDefinition.Action.TARGET_UNIT_OR_POINT:
			_enter_targeting(State.TARGET_DUAL, slot)
	acted.emit(&"aim")


## noh ActivateToolSecondary: toggles autocast of attack modifiers.
func toggle_autocast(slot: int) -> void:
	var caster := get_caster()
	if caster != null:
		caster.toggle_autocast(slot)
		acted.emit(&"autocast")


func learn_ability(slot: int) -> void:
	var caster := get_caster()
	if caster != null and not caster.learn(slot):
		show_error("Can't learn that yet")
	elif caster != null:
		acted.emit(&"learn")


## noh Cast: fires the targeted ability at a unit or the ground.
func _cast(target: int, point: Vector3) -> void:
	var caster := get_caster()
	var ability := get_targeting_ability()
	if caster == null or ability == null:
		_leave_targeting()
		return
	var slot := active_slot
	var spell := SpellCast.new()
	spell.ability = ability
	spell.caster = caster
	spell.registry = registry

	var use_unit := false
	if state == State.TARGET_UNIT:
		var error := ability.check_target(spell, target)
		if not error.is_empty():
			show_error(error)
			return
		use_unit = true
	elif state == State.TARGET_DUAL and target != NONE:
		use_unit = ability.check_target(spell, target).is_empty()

	if not use_unit and not camera.camera.is_position_in_frustum(Terrain.lift(point)):
		return
	if ability.action == AbilityDefinition.Action.ATTACK:
		caster.order_attack(target, _queue(), slot)
		registry.flash(target, COLOR_ENEMY)
	elif use_unit:
		caster.order_cast(slot, target, registry.position_of(target), _queue())
		registry.flash(target, COLOR_SPELL)
	else:
		caster.order_cast(slot, NONE, point, _queue())
		OrderMarker.spawn(get_parent(), point, COLOR_SPELL)
	_leave_targeting()
	acted.emit(&"cast")


func _enter_targeting(target_state: State, slot: int) -> void:
	state = target_state
	active_slot = slot


func _leave_targeting() -> void:
	state = State.HOVER
	active_slot = -1


func _set_order_state(order_state: State) -> void:
	active_slot = -1
	state = order_state


## noh Frame: a targeting state ends if its caster can no longer cast.
func _validate_targeting() -> void:
	if active_slot < 0:
		return
	var caster := get_caster()
	if caster == null or not caster.ability_error(active_slot).is_empty():
		_leave_targeting()


# --- Orders --------------------------------------------------------------------

func give_order_position(order: Order, destination: Vector3, queue: Unit.Queue) -> void:
	# There is no minimap, so a destination off screen can't be what the player meant
	if not camera.camera.is_position_in_frustum(Terrain.lift(destination)):
		return
	var recipients := _order_recipients()
	if recipients.is_empty():
		return
	var color := COLOR_OWN
	if order == Order.ATTACK:
		color = COLOR_ENEMY
	elif order == Order.PATROL:
		color = COLOR_PATROL
	OrderMarker.spawn(get_parent(), destination, color)
	_acknowledge(recipients, order == Order.ATTACK)
	acted.emit({Order.ATTACK: &"attack_move", Order.PATROL: &"patrol"}.get(order, &"move"))
	if queue == Unit.Queue.BACK:
		acted.emit(&"queue")

	if order == Order.PATROL:
		var group := UnitOrder.Group.new()
		for unit in recipients:
			unit.order_patrol(destination, queue, group)
		return

	# DotaCraft: channeling units sit out group moves, unless everyone is channeling
	var movers: Array[Unit] = []
	for unit in recipients:
		if not unit.is_channeling():
			movers.append(unit)
	if movers.is_empty():
		movers = recipients
	var spots: Array[Vector3] = [destination]
	if movers.size() > 1:
		spots = Formation.destinations(movers, destination)
	for i in movers.size():
		if order == Order.ATTACK:
			movers[i].order_attack_move(spots[i], queue)
		else:
			movers[i].order_move(spots[i], queue)


func give_order_unit(order: Order, target: int, queue: Unit.Queue) -> void:
	if order == Order.PATROL:
		give_order_position(order, registry.position_of(target), queue)
		return
	var recipients := _order_recipients()
	if recipients.is_empty():
		return
	if order == Order.ATTACK and not UnitRegistry.are_enemies(registry.team_of(target), registry.player_team):
		order = Order.FOLLOW  # neutrals and allies aren't attacked
		if registry.team_of(target) == 0:
			order = Order.ATTACK
	match order:
		Order.ATTACK:
			registry.flash(target, COLOR_ENEMY)
		Order.TALK:
			registry.flash(target, COLOR_NEUTRAL)
		_:
			registry.flash(target, COLOR_OWN)
	_acknowledge(recipients, order == Order.ATTACK)
	acted.emit({Order.ATTACK: &"attack", Order.TALK: &"talk", Order.MOVE: &"move"}.get(order, &"follow"))
	if queue == Unit.Queue.BACK:
		acted.emit(&"queue")
	for unit in recipients:
		if unit.handle == target:
			continue
		match order:
			Order.ATTACK:
				unit.order_attack(target, queue)
			Order.TALK:
				unit.order_talk(target, queue)
			_:
				unit.order_follow(target, queue)


## One ordered hero answers, the active one if it got the order (Dota: the selected hero's
## move and attack responses).
func _acknowledge(recipients: Array[Unit], attacking: bool) -> void:
	var speaker := get_caster()
	if not recipients.has(speaker):
		speaker = recipients[0]
	speaker.say(&"attack" if attacking else &"move")
	if not speaker.is_voiced():
		Sounds.play(&"acknowledged")  # no voice of its own: the order click


func order_stop() -> void:
	for unit in _order_recipients():
		unit.order_stop()
	acted.emit(&"stop")


func order_hold() -> void:
	var queue := _queue()
	for unit in _order_recipients():
		unit.order_hold(queue)
	acted.emit(&"hold")


## noh StartCommand: right-click picks the order from what is under the cursor.
func _start_command(destination: Vector3, queue: Unit.Queue, order := Order.AUTO) -> void:
	if order == Order.AUTO:
		if hover == NONE:
			order = Order.MOVE
		elif registry.is_neutral(hover):
			order = Order.TALK if registry.dialogue_of(hover) != null else Order.FOLLOW
		elif UnitRegistry.are_enemies(registry.team_of(hover), registry.player_team):
			order = Order.ATTACK
		else:
			order = Order.FOLLOW

	if hover != NONE:
		give_order_unit(order, hover, queue)
	else:
		give_order_position(order, destination, queue)
	state = State.HOVER


## Ctrl restricts orders to the active unit (noh: GetModifier2() ? m_uiActiveControlEntity).
func _order_recipients() -> Array[Unit]:
	var units: Array[Unit] = []
	if Input.is_action_pressed(&"rts_modifier_ctrl"):
		if can_command(active):
			units.append(registry.unit_of(active))
		return units
	for handle in control_selection:
		if can_command(handle):
			units.append(registry.unit_of(handle))
	return units


func _queue() -> Unit.Queue:
	return Unit.Queue.BACK if Input.is_action_pressed(&"rts_modifier_queue") else Unit.Queue.NONE


# --- Selection -----------------------------------------------------------------

func can_command(handle: int) -> bool:
	if not (registry.is_alive(handle) and registry.is_player_unit(handle) and registry.team_of(handle) == registry.player_team):
		return false
	var unit := registry.unit_of(handle)
	return unit == null or not unit.ai  # allied computer heroes play themselves


func get_selected_control() -> int:
	if can_command(active):
		return active
	if control_selection.size() == 1:
		return control_selection[0]
	return NONE


func get_selected_info() -> int:
	if info_selection.size() == 1:
		return info_selection[0]
	return NONE


## The selection the HUD shows: what you inspected, else what you control.
func get_displayed_selection() -> Array[int]:
	return info_selection if not info_selection.is_empty() else control_selection


func is_drag_selecting() -> bool:
	return state == State.SELECT and _start_cursor != cursor_position


func get_selection_rect() -> Rect2:
	return Rect2(_start_cursor, Vector2.ZERO).expand(cursor_position)


func select_hero(index: int) -> void:
	if index < heroes.size():
		select(heroes[index])


## A hero joins the party (a recruit): it gets the next hero hotkey.
func add_hero(unit: Unit) -> void:
	if unit.handle == NONE or heroes.has(unit.handle):
		return
	heroes.append(unit.handle)
	hero_joined.emit(unit)


## noh SelectEntity: selects one unit (portraits, hotkeys). In a targeting state the
## unit becomes the order or spell target instead. Selecting twice centers the camera.
func select(handle: int) -> void:
	if not registry.is_alive(handle):
		return
	match state:
		State.MOVE:
			give_order_unit(Order.MOVE, handle, _queue())
			state = State.HOVER
			return
		State.PATROL:
			give_order_unit(Order.PATROL, handle, _queue())
			state = State.HOVER
			return
		State.ATTACK:
			give_order_unit(Order.ATTACK, handle, _queue())
			state = State.HOVER
			return
		State.TARGET_UNIT, State.TARGET_DUAL:
			_cast(handle, registry.position_of(handle))
			return

	var to_control := can_command(handle)
	var selection := control_selection if to_control else info_selection
	if to_control:
		info_selection.clear()

	var shift := Input.is_action_pressed(&"rts_modifier_queue")
	if shift and selection.has(handle):
		selection.erase(handle)
		return
	if not shift:
		selection.clear()
	if not selection.has(handle):
		selection.append(handle)
		selection.sort()

	var now := Time.get_ticks_msec()
	if now - _last_select_time < DOUBLE_SELECT_TIME_MS and selection.size() == 1 and selection[0] == handle:
		camera.center_on(registry.position_of(handle))
		_last_select_time = 0
		return
	_last_select_time = now


## noh SetControlUnit: picks the active unit by HUD slot; twice quickly selects only it.
func set_control_unit(slot: int, centered := false) -> void:
	var now := Time.get_ticks_msec()
	if not info_selection.is_empty():
		if slot < 0 or slot >= info_selection.size():
			return
		var inspected := info_selection[slot]
		if inspected == _last_set_control and now - _last_set_control_time < DOUBLE_SELECT_TIME_MS:
			select(inspected)
			return
		_last_set_control_time = now
		_last_set_control = inspected
		return

	if slot < 0 or slot >= control_selection.size():
		return
	active = control_selection[slot]
	_leave_targeting()
	if active == _last_set_control and now - _last_set_control_time < DOUBLE_SELECT_TIME_MS:
		select(active)
		return
	_last_set_control_time = now
	_last_set_control = active
	if centered:
		camera.center_on(registry.position_of(active))


## noh DeselectUnit
func deselect_unit(slot: int) -> void:
	var selection := get_displayed_selection()
	if slot >= 0 and slot < selection.size():
		selection.remove_at(slot)


## noh NextUnit / PrevUnit: cycles the active unit inside a group selection, or
## through all of your units when at most one is selected.
func cycle_unit(step: int, centered: bool) -> void:
	acted.emit(&"next_hero")
	if control_selection.size() < 2:
		var own := _own_units()
		if own.is_empty():
			return
		var index := own.find(get_selected_control())
		if index < 0:
			index = 0 if step > 0 else own.size() - 1
		else:
			index = posmod(index + step, own.size())
		active = own[index]
		control_selection.assign([active])
	else:
		var index := control_selection.find(active)
		if index < 0:
			return
		active = control_selection[posmod(index + step, control_selection.size())]
	_leave_targeting()
	if centered and registry.is_alive(active):
		camera.center_on(registry.position_of(active))


# --- Control groups (noh Save/AddTo/RemoveFrom/RecallSelectionSet) ------------

## Hero order, selections and control groups (handles stay valid across a save).
func save_state() -> Dictionary:
	var sets := []
	for saved in _saved_sets:
		sets.append({"handles": saved.handles.duplicate(), "focus": saved.focus})
	return {
		"heroes": heroes.duplicate(),
		"control": control_selection.duplicate(),
		"info": info_selection.duplicate(),
		"active": active,
		"sets": sets,
	}


func load_state(data: Dictionary) -> void:
	heroes.assign(data.heroes)
	control_selection.assign(data.control)
	info_selection.assign(data.info)
	active = data.active
	for i in mini(_saved_sets.size(), data.sets.size()):
		_saved_sets[i].handles.assign(data.sets[i].handles)
		_saved_sets[i].focus = data.sets[i].focus
	_leave_targeting()


func save_selection_set(index: int) -> void:
	var saved := _saved_sets[index]
	saved.handles.assign(control_selection)
	saved.focus = active
	acted.emit(&"group_saved")


func add_to_selection_set(index: int) -> void:
	var saved := _saved_sets[index]
	_clean(saved.handles)
	for handle in control_selection:
		if not saved.handles.has(handle):
			saved.handles.append(handle)
	saved.handles.sort()
	acted.emit(&"group_added")


func remove_from_selection_set(index: int) -> void:
	var saved := _saved_sets[index]
	_clean(saved.handles)
	for handle in control_selection:
		saved.handles.erase(handle)
	if not saved.handles.has(saved.focus):
		saved.focus = saved.handles[0] if not saved.handles.is_empty() else NONE
	acted.emit(&"group_removed")


## Recalling the same group twice quickly centers the camera on its focus unit.
func recall_selection_set(index: int) -> void:
	var saved := _saved_sets[index]
	_clean(saved.handles)
	if saved.handles.is_empty():
		return

	var to_control := saved.handles.any(can_command)
	var selection := control_selection if to_control else info_selection
	selection.assign(saved.handles)
	if to_control:
		info_selection.clear()
	active = saved.focus if registry.is_alive(saved.focus) else NONE
	_leave_targeting()
	acted.emit(&"group_recalled")

	var now := Time.get_ticks_msec()
	if _last_recall_index == index and now - _last_recall_time <= DOUBLE_SELECT_TIME_MS:
		var focus := get_selected_control()
		if to_control and focus != NONE:
			camera.center_on(registry.position_of(focus))
		return
	_last_recall_index = index
	_last_recall_time = now


# --- Box selection (noh StartSelect / UpdateHoverSelection / ApplySelect) -----

func _start_select(screen_position: Vector2) -> void:
	state = State.SELECT
	_start_cursor = screen_position
	_first = hover
	_select_time = Time.get_ticks_msec()


func _update_hover_selection() -> void:
	hover_selection.clear()
	if state != State.SELECT:
		if hover != NONE:
			hover_selection.append(hover)
		return

	var potential := registry.query_screen_rect(camera.camera, get_selection_rect())
	if registry.is_alive(_first) and not potential.has(_first):
		potential.append(_first)

	# Prefer the units this player controls; otherwise inspect whatever was boxed
	_control_selection_mode = true
	for handle in potential:
		if can_command(handle):
			hover_selection.append(handle)
	if not hover_selection.is_empty():
		return
	_control_selection_mode = false
	hover_selection.assign(potential)


func _apply_select() -> void:
	_update_hover_selection()
	state = State.HOVER
	if hover_selection.is_empty():
		_first = NONE
		return

	var selection := control_selection if _control_selection_mode else info_selection
	var last_selected := selection[0] if selection.size() == 1 else NONE

	# Double-click (or Ctrl+click) a unit: also select its kind nearby
	var double_click := _select_time - _last_primary_time < DOUBLE_SELECT_TIME_MS and _first == last_selected
	var boxed := get_selection_rect().size.length() > 8.0
	if registry.is_alive(_first) and (double_click or Input.is_action_pressed(&"rts_modifier_ctrl")):
		acted.emit(&"select_type")
		_last_primary_time = 0
		var kind := registry.definition_of(_first)
		var team := registry.team_of(_first)
		var commandable := can_command(_first)
		for other in registry.query_radius(registry.position_of(_first), DOUBLE_SELECT_RADIUS):
			if registry.definition_of(other) != kind or registry.team_of(other) != team or can_command(other) != commandable \
					or not registry.player_sees(other):
				continue
			if not hover_selection.has(other):
				hover_selection.append(other)

	if _control_selection_mode:
		info_selection.clear()
	var shift := Input.is_action_pressed(&"rts_modifier_queue")
	if not shift:
		selection.clear()
	for handle in hover_selection:
		# Shift+clicking a single selected unit removes it
		if shift and selection.has(handle) and hover_selection.size() == 1:
			selection.erase(handle)
		elif not selection.has(handle):
			selection.append(handle)
	selection.sort()
	_last_primary_time = Time.get_ticks_msec()
	acted.emit(&"box_select" if boxed else &"select")


# --- Per-frame upkeep ----------------------------------------------------------

## noh UpdateCursorTrace: the ground point and the unit under the cursor.
func _update_cursor_trace(screen_position: Vector2, ignore := NONE) -> void:
	var view := camera.camera
	var from := view.project_ray_origin(screen_position)
	var direction := view.project_ray_normal(screen_position)
	# The drawn terrain under the cursor; orders take its gameplay point on the plane y = 0
	var ground := Terrain.trace(from, direction)
	if ground != Vector3.INF:
		trace_position = Vector3(ground.x, 0.0, ground.z)

	# noh skips units while box selecting
	hover = NONE if state == State.SELECT else registry.pick(view, screen_position, ignore)
	hover_item = _pick_item(view, screen_position) if hover == NONE and state == State.HOVER else null


## noh ValidateSelections: drops dead units, falls back to a hero, keeps a valid active unit.
func _validate_selections() -> void:
	_clean(info_selection)
	for i in range(control_selection.size() - 1, -1, -1):
		if not can_command(control_selection[i]):
			control_selection.remove_at(i)
	if control_selection.is_empty():
		for handle in heroes:
			if can_command(handle):
				control_selection.append(handle)
				break
	if not can_command(active) or not control_selection.has(active):
		active = control_selection[0] if not control_selection.is_empty() else NONE
	if not registry.is_alive(hover) or not registry.player_sees(hover):
		hover = NONE


## noh Center / CenterInfo binds: keep the camera on the selection while held.
func _update_center_binds() -> void:
	var focus := NONE
	if Input.is_action_pressed(&"rts_center"):
		focus = get_selected_control()
	elif Input.is_action_pressed(&"rts_center_info"):
		focus = get_selected_info()
		if focus == NONE:
			focus = get_selected_control()
	if focus != NONE:
		camera.center_on(registry.position_of(focus))
		acted.emit(&"center")


func _update_cursor() -> void:
	var shape := Input.CURSOR_ARROW
	var edge := camera.edge_scroll_direction
	if edge.x != 0 and edge.y != 0:
		shape = Input.CURSOR_FDIAGSIZE if edge.x == edge.y else Input.CURSOR_BDIAGSIZE
	elif edge.x != 0:
		shape = Input.CURSOR_HSIZE
	elif edge.y != 0:
		shape = Input.CURSOR_VSIZE
	elif state != State.HOVER and state != State.SELECT:
		shape = Input.CURSOR_CROSS
	elif hover_item != null:
		shape = Input.CURSOR_POINTING_HAND
	if shape != _cursor_shape:
		_cursor_shape = shape
		Input.set_default_cursor_shape(shape)


func _update_highlights() -> void:
	registry.clear_highlights()
	for handle in hover_selection:
		registry.set_highlight(handle, UnitRegistry.HIGHLIGHT_HOVER)
	for handle in control_selection:
		registry.set_highlight(handle, UnitRegistry.HIGHLIGHT_SELECTED)
	for handle in info_selection:
		registry.set_highlight(handle, UnitRegistry.HIGHLIGHT_SELECTED)


# --- Helpers -------------------------------------------------------------------

## The player's living units in handle order, heroes first.
func _own_units() -> Array[int]:
	var own: Array[int] = []
	for handle in heroes:
		if can_command(handle):
			own.append(handle)
	for handle in registry.handles(UnitRegistry.Kind.SUMMON):
		if can_command(handle):
			own.append(handle)
	return own


func _pressed_index(event: InputEvent, pattern: String, count: int, first: int) -> int:
	for i in count:
		if event.is_action_pressed(StringName(pattern % (i + first))):
			return i
	return -1


## Drops dead units, and units gone into the fog (noh ValidateSelections).
func _clean(handles: Array[int]) -> void:
	for i in range(handles.size() - 1, -1, -1):
		if not registry.is_alive(handles[i]) or not registry.player_sees(handles[i]):
			handles.remove_at(i)
