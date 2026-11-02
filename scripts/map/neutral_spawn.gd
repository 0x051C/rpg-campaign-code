@tool
class_name NeutralSpawn
extends Marker3D

## A neutral NPC (villager, quest giver) placed on a map: when the map starts it becomes a
## UnitRegistry row on the neutral team, standing here and facing the marker's +Z (KayKit
## models face +Z). Smart-clicking it with a player unit walks over and talks: its Dialogue
## streams over its head. The editor shows the unit's model where it will stand.
##
## With `recruit_as` it can join the party: recruit() (connect any signal to it, or list it in
## a QuestStep's `recruit`) or `recruit_after_talk` turns it into that hero where it stands.
## A recruited NPC never comes back to its map.

## It joined the party as `hero`.
signal recruited(hero: Unit)
## The player heard it out: its dialogue ran to the end (or it was talked to with nothing to say).
## Connect a Quest's start() to it: a rumor that becomes a quest.
signal talked

@export var definition: UnitDefinition:
	set(value):
		definition = value
		_update_preview()
@export var dialogue: Dialogue
@export var model_scale := 1.0:
	set(value):
		model_scale = value
		_update_preview()
## Off: attacks and spells can't hurt it.
@export var can_be_hurt := false
## Items and gold it drops when it dies (only if it can be hurt).
@export var drops: Array[ItemDefinition] = []
@export var gold := 0
@export_group("Recruit")
## The hero it becomes when it joins the party; empty: it never joins.
@export var recruit_as: UnitDefinition
## Joins once the party has heard all it has to say (or on talking, without a dialogue).
@export var recruit_after_talk := false
## Off: it only appears when spawn() is called (a StoryGate opening: the stranger in the inn).
@export var spawn_on_start := true

var handle := UnitRegistry.NONE

var _preview: Node3D


func _ready() -> void:
	if Engine.is_editor_hint():
		set_notify_transform(true)
		_update_preview()
		return
	if spawn_on_start:
		_spawn.call_deferred()  # after the registry is ready
	else:
		_connect.call_deferred()


## Appears now, if it isn't here yet (connectable to any signal).
func spawn(_a: Variant = null, _b: Variant = null) -> void:
	_spawn()


## Leaves the map (a StoryGate closing what's no longer on offer). spawn() brings it back.
func despawn(_a: Variant = null, _b: Variant = null) -> void:
	var registry := get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	if registry != null and registry.is_alive(handle):
		registry.despawn(handle)
	handle = UnitRegistry.NONE


func _connect() -> void:
	var registry := get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	if registry != null and not registry.dialogue_finished.is_connected(_on_dialogue_finished):
		registry.dialogue_finished.connect(_on_dialogue_finished)
		registry.talked_to.connect(_on_talked_to)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and _preview != null:
		_preview.position.y = Terrain.ground(global_position.x, global_position.z) - global_position.y


func _spawn() -> void:
	_connect()
	var registry := get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	if handle != UnitRegistry.NONE and registry != null and registry.is_alive(handle):
		return  # here already, or restored from a save along with the registry
	if Campaign.current != null and Campaign.current.is_opened(self):
		return  # joined the party earlier
	if registry == null or definition == null:
		push_warning("%s: needs a unit definition and a UnitRegistry in the map" % name)
		return
	var at := Vector3(global_position.x, 0.0, global_position.z)
	handle = registry.spawn_neutral(definition, at, global_rotation.y, dialogue, model_scale, can_be_hurt)
	if not drops.is_empty() or gold > 0:
		registry.set_drops(handle, drops, gold)


func _update_preview() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _preview != null:
		_preview.queue_free()
		_preview = null
	if definition == null or definition.model == null:
		return
	_preview = definition.model.instantiate()  # not owned by the scene: never saved
	add_child(_preview)
	_preview.scale = Vector3.ONE * model_scale
	_preview.position.y = Terrain.ground(global_position.x, global_position.z) - global_position.y


## Joins the party as `recruit_as`, standing where the NPC stood (connectable to any
## signal). Null when it can't: nothing to become, already gone, or the party is full.
func recruit(_a: Variant = null, _b: Variant = null) -> Unit:
	var registry := get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	var map := owner if owner != null else get_tree().current_scene
	if recruit_as == null or registry == null or not registry.is_alive(handle) or map == null \
			or not map.has_method(&"add_party_hero"):
		return null
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	if not map.call(&"party_has_room"):
		if party != null and party.commander != null:
			party.commander.show_error("The party is full")
		return null
	var at := registry.position_of(handle)
	var yaw := registry.yaw_of(handle)
	registry.despawn(handle)
	handle = UnitRegistry.NONE
	Campaign.current.mark_opened(self)  # stays with the party, never back on this map
	var hero: Unit = map.call(&"add_party_hero", recruit_as, at, yaw)
	if hero != null and party != null and party.commander != null:
		party.commander.show_message("%s joins the party" % hero.definition.display_name, PartyInventory.GOOD_NEWS)
	recruited.emit(hero)
	return hero


func _on_dialogue_finished(npc: int, _speaker: int) -> void:
	if npc == handle and handle != UnitRegistry.NONE:
		talked.emit()
		if recruit_after_talk:
			recruit()


func _on_talked_to(npc: int, _speaker: int) -> void:
	if npc == handle and handle != UnitRegistry.NONE and (dialogue == null or dialogue.lines.is_empty()):
		talked.emit()
		if recruit_after_talk:
			recruit()
