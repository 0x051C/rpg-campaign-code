class_name CreepWaves
extends Node

## Creep wave timer ported from noh's CGameServer (SpawnCreeps and the wave block of
## the server frame, src/hon_server/c_gameserver.cpp): every wave interval each
## spawner sends melee and ranged creeps, plus siege creeps every tenth wave, and the
## wave formation grows with the wave count. A spawner with a `hero` sends that hero instead
## of its siege creeps: computer-controlled, at the level of the party's best hero, one at a
## time.

const UNIT_SCENE := preload("res://scenes/unit.tscn")
const GROUP := &"creep_waves"

@export var registry: UnitRegistry
@export var first_wave_delay := 1.0
@export var wave_interval := 30.0  ## g_creepWaveInterval
@export var siege_interval := 10  ## g_creepSiegeInterval
@export var formation_indexes := PackedInt32Array([0, 31, 61, 71, 81, 91])  ## g_creepFormationIndexes
@export var melee_count := PackedInt32Array([3, 4, 5, 5, 5, 6])  ## g_creepMeleeCount
@export var ranged_count := PackedInt32Array([1, 1, 1, 1, 2, 2])  ## g_creepRangedCount
@export var siege_count := PackedInt32Array([1, 1, 1, 2, 2, 2])  ## g_creepSiegeCount

var wave_count := 0

var _clock := 0.0
var _next_wave_time := 0.0


func _ready() -> void:
	add_to_group(GROUP)
	_next_wave_time = first_wave_delay
	Simulation.join(self, Simulation.Order.SPAWNS)


func _simulate(delta: float) -> void:
	_clock += delta
	if _clock >= _next_wave_time:
		spawn_wave()
		wave_count += 1
		_next_wave_time += wave_interval


func save_state() -> Dictionary:
	var heroes := {}
	var active := {}
	for node in get_tree().get_nodes_in_group(&"creep_spawners"):
		heroes[str(node.name)] = (node as CreepSpawner).hero_handle
		active[str(node.name)] = (node as CreepSpawner).active
	return {"wave_count": wave_count, "clock": _clock, "next_wave_time": _next_wave_time, "heroes": heroes,
			"active": active}


func load_state(data: Dictionary) -> void:
	wave_count = data.wave_count
	_clock = data.clock
	_next_wave_time = data.next_wave_time
	var heroes: Dictionary = data.get("heroes", {})
	var active: Dictionary = data.get("active", {})
	for node in get_tree().get_nodes_in_group(&"creep_spawners"):
		(node as CreepSpawner).hero_handle = heroes.get(str(node.name), UnitRegistry.NONE)
		(node as CreepSpawner).active = active.get(str(node.name), (node as CreepSpawner).active)


## noh CGameServer::SpawnCreeps, for the active spawners (or just `only`).
func spawn_wave(only: Array = []) -> void:
	var formation := 0
	for i in formation_indexes.size():
		if wave_count >= formation_indexes[i]:
			formation = i
	var with_siege := wave_count > 0 and wave_count % siege_interval == 0

	for node in get_tree().get_nodes_in_group(&"creep_spawners") if only.is_empty() else only:
		var spawner: CreepSpawner = node
		if not spawner.active:
			continue
		var wave: Array[UnitDefinition] = []
		for i in melee_count[formation]:
			wave.append(spawner.melee)
		for i in ranged_count[formation]:
			wave.append(spawner.ranged)
		if with_siege and spawner.hero != null:
			if not registry.is_alive(spawner.hero_handle):
				spawn_hero(spawner, spawner.formation_position(wave.size()))
		elif with_siege:
			for i in siege_count[formation]:
				wave.append(spawner.siege)
		wave = wave.filter(func(definition: UnitDefinition) -> bool: return definition != null)  # a lane without ranged or siege creeps
		for i in wave.size():
			registry.spawn_npc(wave[i], spawner.team, spawner.formation_position(i), spawner)


## Sends `spawner`'s hero down its lane from `at`, at the level of the party's best hero.
func spawn_hero(spawner: CreepSpawner, at: Vector3) -> Unit:
	var level := 1
	for unit in registry.unit_nodes():
		if UnitRegistry.kind_of(unit.handle) == UnitRegistry.Kind.HERO and not unit.ai \
				and unit.team == registry.player_team:
			level = maxi(level, unit.level)
	var hero: Unit = UNIT_SCENE.instantiate()
	hero.definition = spawner.hero
	hero.team = spawner.team
	hero.registry = registry
	hero.ai = true
	hero.ai_spawner = spawner
	hero.level = level
	hero.position = Vector3(at.x, 0.0, at.z)
	hero.rotation.y = spawner.lane_yaw()
	var parent := registry.get_parent().get_node_or_null(^"Heroes")
	(parent if parent != null else registry.get_parent()).add_child(hero)
	if hero.handle == UnitRegistry.NONE:
		return null
	hero.recalculate_stats()
	hero.skill_points = level  # the brain learns its spells
	spawner.hero_handle = hero.handle
	return hero
