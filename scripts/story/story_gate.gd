class_name StoryGate
extends Node

## Opens when enough story flags are set (Campaign.set_story_flag, QuestStep.set_flags): "two of
## the three jobs are done". Then it shows what was waiting (the stranger in the inn, the road
## onward), hides what's no longer on offer (the third job), sets flags of its own and emits
## `opened`, which any node can be connected to.
##
## Until it opens, the `show` nodes are kept out of the map. It checks when the map starts (a
## load or a return puts everything back the way the flags say) and whenever a story flag
## changes. What only happens once (camps sending their group, flags) is remembered with the
## campaign, so coming back to the map doesn't do it again.
##
## What showing and hiding does, by node: a NeutralSpawn spawns or leaves; a NeutralCamp sends
## its group (once); anything else becomes visible and processing, or hidden and switched off
## (a hidden MapExit can't be used).
##
## A `reversible` gate closes again when its flags stop saying so, putting back what it showed
## and hid: the jobs' roads, open each rested morning and shut once the day is spent.

## It opened (the first time, or again after a load or a return to the map).
signal opened

## The flags it waits for.
@export var flags: Array[StringName] = []
## How many of `flags` must be set; 0: all of them.
@export var needed := 0
## It stays shut while any of these is set.
@export var unless: Array[StringName] = []
## And all of these must be set too (e.g. `rested`: the morning after a night at the inn).
@export var requires: Array[StringName] = []
## Closes again when its flags no longer say it's open.
@export var reversible := false
## Appear when it opens.
@export var show: Array[Node] = []
## Disappear when it opens.
@export var hide: Array[Node] = []
## Set when it opens.
@export var set_flags: Array[StringName] = []
## Cleared when it opens (leaving on a job spends the day: `rested`).
@export var clear_flags: Array[StringName] = []
## The time of day the map turns to when it opens (TimeOfDay presets); empty keeps it.
@export var time_of_day := &""

var is_open := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	for node in show:
		_present(node, false)
	_check.call_deferred()  # after the map's saved state and the campaign's flags are back
	if Campaign.current != null:
		Campaign.current.story_flag_changed.connect(func(_flag: StringName) -> void: _check())


## Whether its flags say it's open.
func is_due() -> bool:
	if Campaign.current == null:
		return false
	for flag in unless:
		if Campaign.current.has_story_flag(flag):
			return false
	for flag in requires:
		if not Campaign.current.has_story_flag(flag):
			return false
	var set := 0
	for flag in flags:
		if Campaign.current.has_story_flag(flag):
			set += 1
	return set >= (flags.size() if needed <= 0 else needed)


func _check() -> void:
	if not is_inside_tree():
		return
	if is_open:
		if reversible and not is_due():
			_close()
		return
	if not is_due():
		return
	is_open = true
	var first_time := not Campaign.current.is_opened(self)
	Campaign.current.mark_opened(self)
	for node in hide:
		_present(node, false)
	for node in show:
		_present(node, true, first_time)
	if first_time or reversible:
		for flag in set_flags:
			Campaign.current.set_story_flag(flag)
		for flag in clear_flags:
			Campaign.current.set_story_flag(flag, false)
	if not time_of_day.is_empty():
		TimeOfDay.apply(get_tree().current_scene, time_of_day)
	opened.emit()


## Its flags no longer hold: what it showed goes, what it hid comes back.
func _close() -> void:
	is_open = false
	for node in show:
		_present(node, false)
	for node in hide:
		_present(node, true, false)


func _present(node: Node, present: bool, first_time := true) -> void:
	if node == null:
		return
	if node is NeutralSpawn:
		if present:
			(node as NeutralSpawn).spawn()
		else:
			(node as NeutralSpawn).despawn()
	elif node is NeutralCamp:
		if present and first_time:
			(node as NeutralCamp).spawn_group()
	else:
		if node is Node3D:
			(node as Node3D).visible = present
		elif node is CanvasItem:
			(node as CanvasItem).visible = present
		node.process_mode = Node.PROCESS_MODE_INHERIT if present else Node.PROCESS_MODE_DISABLED
