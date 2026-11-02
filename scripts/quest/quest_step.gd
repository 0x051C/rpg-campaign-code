@tool
class_name QuestStep
extends Node

## One step of a Quest (its parent): an objective, shown in the quest tracker, and the goal
## that completes it. While it's the current step its `markers` show (on the map and the
## overlay map) and its trigger listens; when the goal is met it shows `message`, sets its
## story flags, activates its creep spawners, emits `completed` (wire anything to it in the
## Node > Signals dock) and hands over to `next`, or else the next QuestStep sibling.
##
## Goals: REACH a MapTrigger, TALK to a NeutralSpawn's NPC, KILL that NPC or `kill_count`
## units of `kill_unit`, a story FLAG being set (Campaign.set_story_flag), the party having an
## ITEM (in the bag, the combine grid or worn: a rumor's Lightbrand), or MANUAL: call complete(),
## e.g. from another node's signal.

signal started
signal completed

enum Goal { REACH, TALK, KILL, FLAG, MANUAL, ITEM }

const FLAG_CHECK_TIME := 0.5

## What the tracker shows while this step is current.
@export_multiline var objective := ""
@export var goal := Goal.REACH:
	set(value):
		goal = value
		update_configuration_warnings()
## REACH: the area a hero has to enter.
@export var trigger: MapTrigger:
	set(value):
		trigger = value
		update_configuration_warnings()
## TALK: who to talk to. KILL: who to kill (or leave empty and use kill_unit).
@export var npc: NeutralSpawn:
	set(value):
		npc = value
		update_configuration_warnings()
## KILL without an npc: how many of which unit the party has to kill.
@export var kill_unit: UnitDefinition
@export var kill_count := 1
## FLAG: the story flag that completes it.
@export var flag: StringName
## ITEM: the item the party has to have.
@export var item: ItemDefinition
## Shown only while this step is current: objective markers, a quest giver's "!".
@export var markers: Array[MapMarker] = []

@export_group("On completion")
## Shown in the message line.
@export_multiline var message := ""
@export var set_flags: Array[StringName] = []
## Gold paid to the party when it's done (a job's pay).
@export var reward_gold := 0
@export var activate_spawners: Array[CreepSpawner] = []
## Neutral NPCs that join the party (their `recruit_as`).
@export var recruit: Array[NeutralSpawn] = []
## The step after this one; empty: the next QuestStep sibling, or the quest ends.
@export var next: QuestStep

var kills := 0  ## KILL by unit type: how many so far (saved with the quest)

var _active := false
var _flag_timer := 0.0


## Becomes the quest's current step: markers show, the goal listens.
func begin() -> void:
	_active = true
	for marker in markers:
		if marker != null:
			marker.visible = true
	var registry := _registry()
	match goal:
		Goal.REACH:
			if trigger != null:
				trigger.enable()
				if not trigger.reached.is_connected(_on_reached):
					trigger.reached.connect(_on_reached)
				if trigger.fired and trigger.once:
					complete.call_deferred()  # reached before this step started
		Goal.TALK:
			if registry != null and not registry.talked_to.is_connected(_on_talked):
				registry.talked_to.connect(_on_talked)
		Goal.KILL:
			if registry != null and not registry.unit_died.is_connected(_on_died):
				registry.unit_died.connect(_on_died)
			if npc != null and npc.handle != UnitRegistry.NONE and registry != null and not registry.is_alive(npc.handle):
				complete.call_deferred()  # already dead
	started.emit()


## Stops listening and hides the markers (also for steps that never ran).
func end() -> void:
	_active = false
	for marker in markers:
		if marker != null:
			marker.visible = false
	if trigger != null and trigger.reached.is_connected(_on_reached):
		trigger.reached.disconnect(_on_reached)
	var registry := _registry()
	if registry != null:
		if registry.talked_to.is_connected(_on_talked):
			registry.talked_to.disconnect(_on_talked)
		if registry.unit_died.is_connected(_on_died):
			registry.unit_died.disconnect(_on_died)


func is_active() -> bool:
	return _active


## The goal is met: on to the next step (also connectable to any signal: MANUAL goals).
func complete(_a: Variant = null, _b: Variant = null) -> void:
	if not _active:
		return
	end()
	if not message.is_empty():
		var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
		if party != null and party.commander != null:
			party.commander.show_message(message, Color(1.0, 0.85, 0.4))
			Sounds.play(&"news")
	for story_flag in set_flags:
		Campaign.current.set_story_flag(story_flag)
	if reward_gold > 0:
		var purse := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
		if purse != null:
			purse.add_gold(reward_gold)
			if purse.commander != null:
				purse.commander.show_message("+%d gold" % reward_gold, Color(1.0, 0.85, 0.3))
	for spawner in activate_spawners:
		if spawner != null:
			spawner.activate()
	for npc_to_recruit in recruit:
		if npc_to_recruit != null:
			npc_to_recruit.recruit()
	completed.emit()
	var quest := get_parent() as Quest
	if quest != null:
		quest.step_completed(self)


## "Kill wolves (2/5)", or the objective as written.
func tracker_text() -> String:
	if goal == Goal.KILL and npc == null and kill_count > 1:
		return "%s (%d/%d)" % [objective, kills, kill_count]
	return objective


func _ready() -> void:
	if not Engine.is_editor_hint():
		Simulation.join(self, Simulation.Order.TRIGGERS)


func _simulate(delta: float) -> void:
	if Engine.is_editor_hint() or not _active or (goal != Goal.FLAG and goal != Goal.ITEM):
		return
	_flag_timer -= delta
	if _flag_timer <= 0.0:
		_flag_timer = FLAG_CHECK_TIME
		if goal == Goal.FLAG and Campaign.current.has_story_flag(flag):
			complete()
		elif goal == Goal.ITEM and item != null:
			var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
			if party != null and party.has_item(item):
				complete()


func _on_reached(_hero: Unit) -> void:
	complete()


func _on_talked(npc_handle: int, _speaker: int) -> void:
	if npc != null and npc_handle == npc.handle:
		complete()


func _on_died(handle: int, killer: int) -> void:
	var registry := _registry()
	if npc != null:
		if handle == npc.handle:
			complete()
		return
	if kill_unit == null or not registry.definition_of(handle).is_a(kill_unit):  # its leveled copies count too
		return
	if killer != UnitRegistry.NONE and registry.team_of(killer) != registry.player_team:
		return  # someone else's kill
	kills += 1
	var quest := get_parent() as Quest
	if quest != null:
		quest.save()
	if kills >= kill_count:
		complete()


func _registry() -> UnitRegistry:
	if not is_inside_tree():
		return null
	return get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if not get_parent() is Quest:
		warnings.append("A QuestStep belongs under a Quest node.")
	match goal:
		Goal.REACH:
			if trigger == null:
				warnings.append("REACH needs a trigger (a MapTrigger).")
		Goal.TALK:
			if npc == null:
				warnings.append("TALK needs an npc (a NeutralSpawn).")
		Goal.KILL:
			if npc == null and kill_unit == null:
				warnings.append("KILL needs an npc or a kill_unit.")
		Goal.FLAG:
			if flag.is_empty():
				warnings.append("FLAG needs a story flag name.")
		Goal.ITEM:
			if item == null:
				warnings.append("ITEM needs an item.")
	return warnings
