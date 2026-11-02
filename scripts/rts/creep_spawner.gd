class_name CreepSpawner
extends Marker3D

## A team's creep spawn point, ported from noh's CEntityCreepSpawner and its CLane
## (src/hon_shared/c_entitycreepspawner.cpp, c_lane.cpp). The lane is a chain of lane
## nodes leading towards the enemy; creeps always head for the nearest waypoint that
## is still ahead of them. Like noh's g_creepTeam1Melee / g_creepTeam2Melee cvars,
## each spawner names the creep types its team sends.

## It started sending creeps (activate()).
signal activated

const FORMATION_COLUMNS := 3
const FORMATION_SPACING := 1.5
## CLane::GetNextWaypoint ignores waypoints closer than 100 noh units.
const WAYPOINT_SKIP_DISTANCE := 100.0 / RTSCamera.NOH_UNITS_PER_METER

@export var team := 1
@export var lane_nodes: Array[Node3D] = []
## Size of the creeps this spawner sends (a map can shrink its neutrals).
@export var creep_scale := 1.0
## Off: sends nothing until activate(), e.g. from a MapTrigger's `reached` or a QuestStep's
## `completed` signal (Node > Signals dock), or its `activate_spawners` list.
@export var active := true
## Activates it when a hero reaches this trigger (a shortcut for wiring the signal).
@export var start_trigger: MapTrigger
## On activation, send a wave right away instead of waiting for the next one.
@export var wave_on_activate := true

@export_group("Creeps")
@export var melee: UnitDefinition
@export var ranged: UnitDefinition
@export var siege: UnitDefinition
## Sent instead of the siege creeps when set: a computer-controlled hero (HeroBrain) that walks
## this lane at the party's level. Only one at a time; the next siege wave replaces a dead one.
@export var hero: UnitDefinition

@export_group("Level")
## Added to the map's monster level (UnitRegistry.monster_level) for what it sends (DIRECTION.md 2).
@export var level_bonus := 0
## The chance each creep it sends is a champion, with random modifiers (data/modifiers).
@export_range(0.0, 1.0) var champion_chance := 0.0
## Modifiers everything it sends has (a boss's), on top of any it rolls.
@export var modifiers: Array[MonsterModifier] = []

var hero_handle := UnitRegistry.NONE  ## the hero this spawner sent last

var _waypoints := PackedVector3Array()
var _directions := PackedVector3Array()


func _ready() -> void:
	add_to_group(&"creep_spawners")
	if start_trigger != null:
		start_trigger.reached.connect(activate)
	for node in lane_nodes:
		_add_waypoint(node.global_position)


## The modifiers of the next monster it sends at `level`: its own, and maybe a champion's roll.
func next_modifiers(level: int) -> Array[MonsterModifier]:
	return roll_modifiers(level)


## Its `modifiers`, plus random ones with `champion_chance`: one, a second from level 4 and a third
## from level 7, each half the time.
func roll_modifiers(level: int) -> Array[MonsterModifier]:
	var picked: Array[MonsterModifier] = modifiers.duplicate()
	if champion_chance > 0.0 and randf() < champion_chance:
		var count := 1 + (1 if level >= 4 and randf() < 0.5 else 0) + (1 if level >= 7 and randf() < 0.5 else 0)
		for modifier in MonsterModifier.roll(count):
			if not picked.has(modifier):
				picked.append(modifier)
	return picked


## Whether it has lane nodes; its NPCs without one (a NeutralCamp's) go back to their own spots.
func has_lane() -> bool:
	return not _waypoints.is_empty()


## noh CLane::GetNextWaypoint: the closest waypoint that is ahead of `from` and not
## too close, searching onwards from the current one; the lane's end otherwise.
func next_waypoint(from: Vector3, current: Vector3) -> Vector3:
	if _waypoints.is_empty():
		return global_position
	var best := _waypoints[_waypoints.size() - 1]
	var best_distance := INF
	for i in range(maxi(_waypoints.find(current), 0), _waypoints.size()):
		var offset := _flat(from - _waypoints[i])
		if offset.dot(_directions[i]) >= 0.0:
			continue  # already past it
		var distance := offset.length_squared()
		if distance < WAYPOINT_SKIP_DISTANCE * WAYPOINT_SKIP_DISTANCE:
			continue
		if distance < best_distance:
			best_distance = distance
			best = _waypoints[i]
	return best


## Spawn spot for the index-th creep of a wave: rows facing down the lane.
func formation_position(index: int) -> Vector3:
	var forward := _lane_forward()
	var right := forward.cross(Vector3.UP)
	var column := index % FORMATION_COLUMNS
	var row := floorf(float(index) / FORMATION_COLUMNS)
	return global_position + right * (column - (FORMATION_COLUMNS - 1) * 0.5) * FORMATION_SPACING - forward * row * FORMATION_SPACING


## Yaw that faces down the lane (models face +Z).
func lane_yaw() -> float:
	var forward := _lane_forward()
	return atan2(forward.x, forward.z)


## noh CLane::AddWaypoint
func _add_waypoint(point: Vector3) -> void:
	if not _waypoints.is_empty():
		var last := _waypoints.size() - 1
		_directions[last] = _flat(point - _waypoints[last]).normalized()
	_waypoints.append(point)
	_directions.append(Vector3.ZERO)


func _lane_forward() -> Vector3:
	if _waypoints.is_empty():
		return Vector3.FORWARD
	return _flat(_waypoints[0] - global_position).normalized()


static func _flat(vector: Vector3) -> Vector3:
	return Vector3(vector.x, 0.0, vector.z)


## Starts sending creeps; connectable to any signal (the arguments are ignored).
func activate(_a: Variant = null, _b: Variant = null) -> void:
	if active:
		return
	active = true
	activated.emit()
	if wave_on_activate:
		var waves := get_tree().get_first_node_in_group(CreepWaves.GROUP) as CreepWaves
		if waves != null:
			waves.spawn_wave([self])


func deactivate(_a: Variant = null, _b: Variant = null) -> void:
	active = false
