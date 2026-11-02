extends Node3D

## The root of every map: bakes the navigation mesh and, when the map starts fresh,
## spawns the player's three heroes next to their creep spawner. Creep waves come from
## the CreepSpawner nodes (driven by CreepWaves) and meet in the center of the lane.
##
## It also gathers the map's state for a save and puts it back (Campaign; SAVES.md):
## the registry's rows, the heroes and summons, the party's items, corpses, waves,
## selections and the camera. Neutral NPCs keep their handles, items already picked up
## stay gone.

const UNIT_SCENE := preload("res://scenes/unit.tscn")
const PLAYER_TEAM := 1
const HERO_SPACING := 2.5
const DEFAULT_PARTY: Array[UnitDefinition] = [
	# preload("res://data/units/knight.tres"),
	# preload("res://data/units/ranger.tres"),
	# preload("res://data/units/mage.tres"),
	preload("res://data/units/ranger.tres")
]

## Shown in save slots and messages; the root node's name when empty.
@export var map_name := ""
## The heroes a fresh start of this map spawns (at most UnitRegistry.MAX_HEROES); empty:
## Knight, RWBY and Mage.
@export var starting_party: Array[UnitDefinition] = []

@onready var _navigation: NavigationRegion3D = $NavigationRegion3D
var _walk_grid: WalkGrid
var _defeat: DefeatWindow  ## shown once the whole party has fallen
@onready var _registry: UnitRegistry = $UnitRegistry
@onready var _heroes: Node3D = $Heroes
@onready var _commander: Commander = $Commander
@onready var _camera: RTSCamera = $RTSCamera
@onready var _hero_start: Marker3D = $HeroStart
@onready var _party: PartyInventory = $Party
@onready var _corpses: CorpseField = $Corpses


func _ready() -> void:
	_navigation.bake_navigation_mesh(false)
	# Units check their steps against this instead of querying the navigation map every tick
	WalkGrid.current = WalkGrid.from_navigation_mesh(_navigation.navigation_mesh, _navigation.global_transform)
	_walk_grid = WalkGrid.current
	_registry.unit_died.connect(_on_unit_died)
	_add_enemy_panel()
	if Campaign.current.enter_map(self):
		return
	var party := starting_party if not starting_party.is_empty() else DEFAULT_PARTY
	for i in party.size():
		var hero := _spawn_hero(party[i], _hero_spot(_hero_start, i))
		if hero.handle != UnitRegistry.NONE:
			_commander.heroes.append(hero.handle)
	_place_party()
	_commander.select_hero(0)
	_camera.center_on(_hero_start.global_position)
	var leader := _registry.unit_of(_commander.heroes[0]) if not _commander.heroes.is_empty() else null
	if leader != null:
		leader.say(&"spawn")  # a new game: the first hero's entrance line


func _exit_tree() -> void:
	if WalkGrid.current == _walk_grid:
		WalkGrid.current = null


func _spawn_hero(definition: UnitDefinition, at: Vector3) -> Unit:
	var hero: Unit = UNIT_SCENE.instantiate()
	hero.definition = definition
	hero.team = PLAYER_TEAM
	hero.registry = _registry
	hero.position = at
	hero.rotation.y = PI  # KayKit models face +Z; face north up the lane
	_heroes.add_child(hero)
	return hero


## A hero fell: when none is left standing, the party is defeated (DefeatWindow).
## Every map's HUD gets the enemy bar and card (EnemyPanel), without placing it in each scene.
func _add_enemy_panel() -> void:
	var hud := get_node_or_null(^"HUD")
	if hud == null or hud.get_node_or_null(^"EnemyPanel") != null:
		return
	var panel := EnemyPanel.new()
	panel.name = &"EnemyPanel"
	panel.commander = _commander
	hud.add_child(panel)


func _on_unit_died(handle: int, _killer: int) -> void:
	if not _commander.heroes.has(handle):
		return
	if not get_tree().get_nodes_in_group(ArenaChallenge.GROUP).is_empty():
		return  # falling in the arena isn't a defeat: Bram's men drag the party out
	await get_tree().create_timer(2.0).timeout  # the last one falls first (died is told before the body falls)
	if is_inside_tree() and not is_instance_valid(_defeat) and not party_units().any(func(unit: Unit) -> bool: return unit.is_alive()):
		_defeat = DefeatWindow.new()
		get_tree().root.add_child(_defeat)


## The heroes stand on the map: what they keep at their side comes too (Maren's Brook).
func _place_party() -> void:
	for unit in party_units():
		unit.on_placed()
	if Campaign.current.has_story_flag(ArenaChallenge.FATIGUE_FLAG):  # a day in the Pit, not slept off yet
		ArenaChallenge.tire(party_units())


## Whether another hero can join (the party holds UnitRegistry.MAX_HEROES).
func party_has_room() -> bool:
	return _commander.heroes.size() < UnitRegistry.MAX_HEROES


## A hero joining during play (NeutralSpawn.recruit): standing at `at`, at the level of the
## party's best hero with that many skill points to spend. Null when the party is full.
func add_party_hero(definition: UnitDefinition, at: Vector3, yaw: float) -> Unit:
	if not party_has_room():
		return null
	var level := 1
	for unit in party_units():
		level = maxi(level, unit.level)
	var hero := _spawn_hero(definition, Vector3(at.x, 0.0, at.z))
	if hero.handle == UnitRegistry.NONE:
		return null
	hero.rotation.y = yaw
	hero.level = level
	hero.experience = Unit.EXPERIENCE_TABLE[level - 1]
	hero.skill_points = level
	hero.recalculate_stats()
	_registry.set_health(hero.handle, _registry.max_health_of(hero.handle))
	_commander.add_hero(hero)
	hero.on_placed()
	return hero


func _hero_spot(start: Node3D, index: int) -> Vector3:
	var offset := Vector3((index - (UnitRegistry.MAX_HEROES - 1) * 0.5) * HERO_SPACING, 0.0, 0.0)
	return Vector3(start.global_position.x, 0.0, start.global_position.z) + start.global_basis * offset


# --- Saving --------------------------------------------------------------------

## The heroes, in hotkey order.
func party_units() -> Array[Unit]:
	var units: Array[Unit] = []
	for handle in _commander.heroes:
		var unit := _registry.unit_of(handle)
		if unit != null:
			units.append(unit)
	return units


## The whole map as plain data.
func save_world() -> Dictionary:
	var units := []
	for unit in _registry.unit_nodes():
		units.append(unit.save_state())
	var neutrals := {}
	for spawn in find_children("*", "NeutralSpawn", true, false):
		neutrals[str(get_path_to(spawn))] = (spawn as NeutralSpawn).handle
	var world := {
		"registry": _registry.save_state(),
		"units": units,
		"neutrals": neutrals,
		"party": _party.save_state(),
		"corpses": _corpses.save_state(),
		"commander": _commander.save_state(),
		"camera": _camera.save_state(),
	}
	var waves := get_node_or_null(^"CreepWaves") as CreepWaves
	if waves != null:
		world.waves = waves.save_state()
	world.loot = []
	for node in get_tree().get_nodes_in_group(ItemPickup.RUNTIME_GROUP):
		if not node.is_queued_for_deletion():
			world.loot.append((node as ItemPickup).save_state())
	return world


## Puts a saved map back: rows first, then the nodes that sit on them.
func restore_world(world: Dictionary) -> void:
	_registry.load_state(world.registry)
	for data: Dictionary in world.units:
		var unit := Unit.from_state(data, _registry)
		_heroes.add_child(unit)
		unit.restore_state(data)
	for path: String in world.neutrals:
		var spawn := get_node_or_null(path) as NeutralSpawn
		if spawn != null:
			spawn.handle = world.neutrals[path]  # already a restored row; don't spawn another
	_party.load_state(world.party)
	_corpses.load_state(world.corpses)
	_commander.load_state(world.commander)
	_camera.load_state(world.camera)
	var waves := get_node_or_null(^"CreepWaves") as CreepWaves
	if waves != null and world.has("waves"):
		waves.load_state(world.waves)
	for entry: Dictionary in world.get("loot", []):
		ItemPickup.from_state(self, entry, entry.position)


## What travels to the next map: the heroes' progress and equipment, and the bag.
func save_party() -> Dictionary:
	var heroes := []
	for unit in party_units():
		heroes.append(unit.save_state())
	return {"heroes": heroes, "inventory": _party.save_state()}


## The party arriving from another map, at the marker `arrival` or the hero start.
func receive_party(party: Dictionary, arrival: String) -> void:
	var start := get_node_or_null(arrival) as Node3D if not arrival.is_empty() else null
	if start == null:
		start = _hero_start
	for i in party.heroes.size():
		var data: Dictionary = party.heroes[i]
		var unit := Unit.from_state(data, _registry, _hero_spot(start, i))
		unit.rotation.y = PI if start == _hero_start else start.global_rotation.y
		_heroes.add_child(unit)
		unit.restore_state(data, true)
		if unit.handle != UnitRegistry.NONE:
			_commander.heroes.append(unit.handle)
	_party.load_state(party.inventory)
	_place_party()
	_commander.select_hero(0)
	_camera.center_on(start.global_position)


## Items and gold dropped while playing that are still on the ground, as plain data.
func loot_left_behind() -> Array:
	var loot := []
	for node in get_tree().get_nodes_in_group(ItemPickup.RUNTIME_GROUP):
		if not node.is_queued_for_deletion():
			loot.append((node as ItemPickup).save_state())
	return loot


## Loot the party left here last time, laid out next to where it arrives.
func place_loot_at_entrance(items: Array, arrival: String) -> void:
	var start := get_node_or_null(arrival) as Node3D if not arrival.is_empty() else null
	if start == null:
		start = _hero_start
	# Where the arriving heroes look: a marker's +Z (models face +Z), north at the hero start
	var ahead := start.global_basis.z.normalized() if start != _hero_start else Vector3.FORWARD
	for i in items.size():
		var row := Vector3(ahead.z, 0.0, -ahead.x) * ((i % 6) - 2.5) * 0.7
		var at := start.global_position + ahead * (3.0 + floori(i / 6.0) * 0.8) + row
		ItemPickup.from_state(self, items[i], at)


func remove_taken_pickups(paths: Array) -> void:
	for path: String in paths:
		var pickup := get_node_or_null(path)
		if pickup != null:
			pickup.queue_free()
