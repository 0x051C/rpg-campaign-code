class_name NeutralCamp
extends CreepSpawner

## A camp of neutral creatures, like HoN's jungle camps and Kongor's pit: they stand at their
## spots on UnitRegistry.CREATURE_TEAM, enemies of every side, and keep to themselves (a short
## aggro range in their definitions). Ordering an attack on one pulls the whole camp onto the
## attacker (UnitRegistry.attack_order_aggro); once the fight moves too far they walk back here,
## the end of their empty lane. When none is left, a new group comes after `respawn_time`.
##
## Like a HoN camp controller it has a few groups of creatures and sends one of them each time,
## picked at random: `creatures[i]` stands at `spots[i]` (from the camp) at size `sizes[i]` in group
## `groups[i]`, and drops `gold[i]`. Each creature walks back to its own spot, not to the camp's
## middle, and stands still there. It sends no creep waves.

const CHECK_TIME := 10.0

@export var creatures: Array[UnitDefinition] = []
@export var spots := PackedVector3Array()
@export var sizes := PackedFloat32Array()
@export var groups := PackedInt32Array()
@export var gold := PackedInt32Array()
@export var respawn_time := 60.0
## At most this many creatures of the chosen group; 0 sends the whole group.
@export var camp_size := 1
## Off: no group until spawn_group() is called (a StoryGate opening: the Risen hero).
@export var spawn_on_start := true

var _registry: UnitRegistry
var _empty_time := 0.0
var _check := 0.0
var _group_modifiers: Array[MonsterModifier] = []  ## the group being sent: all champions alike, or none


## A camp's group is one pack: every member has the modifiers rolled for the group.
func next_modifiers(_level: int) -> Array[MonsterModifier]:
	return _group_modifiers


func _init() -> void:
	team = UnitRegistry.CREATURE_TEAM
	active = false  # no creep waves


func _ready() -> void:
	super._ready()
	Simulation.join(self, Simulation.Order.SPAWNS)
	_start.call_deferred()  # after the map restored a save, if it did


func _start() -> void:
	_registry = get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	if spawn_on_start and _registry != null and _registry.npcs_of(self).is_empty():
		spawn_group()  # a fresh map: after loading a save they are back already


func _simulate(delta: float) -> void:
	if _registry == null:
		return
	_check -= delta
	if _check > 0.0:
		return
	_check = CHECK_TIME
	if not _registry.npcs_of(self).is_empty() or respawn_time <= 0.0:
		_empty_time = 0.0
		return  # respawn_time 0: once gone, gone (a story camp)
	_empty_time += CHECK_TIME
	if _empty_time >= respawn_time:
		_empty_time = 0.0
		spawn_group()


## Sends one of the camp's groups, picked at random.
func spawn_group() -> void:
	var group_ids: Array[int] = []
	for i in creatures.size():
		var group := groups[i] if i < groups.size() else 0
		if not group_ids.has(group):
			group_ids.append(group)
	if group_ids.is_empty():
		return
	var chosen: int = group_ids.pick_random()
	_group_modifiers = roll_modifiers(_registry.monster_level + level_bonus)  # a champion pack shares them
	var sent := 0
	for i in creatures.size():
		if (groups[i] if i < groups.size() else 0) != chosen or creatures[i] == null:
			continue
		if camp_size > 0 and sent >= camp_size:
			break
		sent += 1
		creep_scale = sizes[i] if i < sizes.size() else 1.0  # spawn_npc reads the spawner's size
		var at := global_position + (spots[i] if i < spots.size() else Vector3.ZERO)
		var handle := _registry.spawn_npc(creatures[i], team, Vector3(at.x+i*.2, 0.0, at.z+i*.2), self)
		if handle != UnitRegistry.NONE and i < gold.size() and gold[i] > 0:
			_registry.set_drops(handle, [], gold[i])
