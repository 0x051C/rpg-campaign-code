class_name UnitRegistry
extends Node3D

## Every combatant as data: one store per kind (heroes, NPCs, summons), each a structure of
## arrays in native code (UnitStore, native/src/core), and the kind in every handle's shape:
##
##     handle = generation << 12 | kind << 9 | index
##
## so code goes straight to the right store by looking at the handle, and each kind keeps only
## what it needs (a creep's lane and swing, nothing of a hero's). Within a store the living sit
## packed together and the fallen in their own arrays; a unit's row moves from one to the other
## when it dies. The generation makes a handle to a unit that's gone stop resolving.
##
## Non-player characters (allied and enemy creeps) exist only as data. Their behavior runs in
## the native core every tick of the game's clock (Simulation; noh's creep behavior: attack-move
## along the lane, see ICreepEntity::ServerFrameThink), which also asks the NavigationServer for
## their paths, on several threads at once. This registry applies what it reports (swings that
## landed, bodies to bury), and draws them through pooled model proxies that hold no game state,
## between their last two ticks so they move smoothly at any frame rate. The player's heroes and
## summons keep their node (body, navigation agent, animation) and mirror into their row every
## physics step, so picking, targeting, damage and auras treat everyone alike.
##
## Creeps pick targets the noh way: every BEHAVIOR_UPDATE_TIME the highest threat in aggro range
## (creeps before player units, nearer first), and an attack order on a hero pulls the aggro of
## that hero's creeps around the attacker for a moment.
##
## Neutral NPCs (NEUTRAL_TEAM: villagers, quest givers) are NPCs without a lane: they stand where
## they were placed, are nobody's enemy, and turn to whoever talks to them.
##
## With a FogOfWar on the map a team only targets, and the player only sees and picks, the units
## its sight reaches (`sighted` bits, noh's VIS_SIGHTED); without one everyone sees all.

enum Kind { HERO, NPC, SUMMON }
enum Life { FREE, ALIVE, DYING, DEAD }  ## DEAD: fallen heroes, whose bodies never decay
enum Anim { NONE, IDLE, RUN, ATTACK, DEATH }

## A neutral NPC was talked to (smart-click); the DialogueOverlay shows what it says.
signal talked_to(npc: int, speaker: int)
## A unit died; `killer` is NONE when nothing in particular killed it.
signal unit_died(handle: int, killer: int)
## An NPC finished saying its lines (DialogueOverlay).
signal dialogue_finished(npc: int, speaker: int)
## An attack on `victim` missed: it evaded.
signal attack_evaded(victim: int)
## `victim` parried an attack from `source`.
signal attack_parried(victim: int, source: int)

const NONE := -1
const KINDS: Array[Kind] = [Kind.HERO, Kind.NPC, Kind.SUMMON]
const INDEX_BITS := 9
const PER_KIND := 1 << INDEX_BITS  ## units of one kind at once
const NEUTRAL_TEAM := 0  ## never targets anyone, never targeted, never attacked
const CREATURE_TEAM := 3  ## neutral creatures (NeutralCamp): enemies of every side, fighting whoever attacks them
const MAX_TEAMS := 8  ## team ids 0..7
const GROUP := &"unit_registry"  ## map nodes find the registry through it (NeutralSpawn)
const MAX_HEROES := 3
const HIGHLIGHT_HOVER := 1
const HIGHLIGHT_SELECTED := 2
const DYING_TIME := 1.2  ## death animation before the body becomes a corpse marker
## noh BEHAVIOR_UPDATE_MS. The native core keeps the creep behavior's numbers (leash, repath,
## threat...) next to the code that uses them: native/src/core/units.zig.
const BEHAVIOR_UPDATE_TIME := 0.5
const AURA_UPDATE_TIME := 0.25
const RUN_ANIMATION_SPEED := 5.0
const PICK_SLOP := 4.0  ## extra pixels around a unit, like noh's widening cursor traces
const TALK_REPEAT_TIME := 0.5  ## talking to the same NPC again this soon counts as the same click
const EXPERIENCE_RANGE := 1200.0 / RTSCamera.NOH_UNITS_PER_METER  ## heroes this close share a kill's experience
const ATTACK_AGGRO_TRIGGER_RANGE := 700.0 / RTSCamera.NOH_UNITS_PER_METER  ## g_unitAttackAggroTriggerRange
const RING_MESH_RADIUS := 0.67
## Around a creep model, generous: an animation starts before the model comes into view.
const PROXY_SCREEN_BOX := AABB(Vector3(-2.0, -0.5, -2.0), Vector3(4.0, 4.5, 4.0))
const CHAMPION_SCALE := 1.2  ## champions stand a little taller than their kind
const ELEMENT_COLORS := {&"fire": Color(1.0, 0.45, 0.12), &"ice": Color(0.55, 0.8, 1.0), &"lightning": Color(0.7, 0.75, 1.0),
		&"water": Color(0.3, 0.6, 1.0)}
const FLOATS_PER_INSTANCE := 16  ## 3x4 transform + color
const GROUND_DECAL := preload("res://shaders/ground_decal.gdshader")
const MONITOR_SIMULATION := &"RTS/Simulation (ms)"  ## FrameMonitor: the last tick's creep simulation
const MONITOR_PRESENTATION := &"RTS/Proxies and rings (ms)"  ## the last frame's model proxies and selection rings
const MONITOR_ROWS := &"RTS/Alive rows"

@export var corpses: CorpseField
@export var player_team := 1
## The developer console's god mode (DevConsole): units of this team take no damage; -1: off.
var god_team := -1
## Multiplies every kill's experience bounty; DotaCraft's values are tuned for long games.
@export var experience_rate := 1
## The map's monsters' level (DIRECTION.md 2): what its camps and spawners send is leveled to it,
## plus their own level_bonus.
@export var monster_level := 1
## How generous its monsters are with loot (LootRoller): 1 as the tables say, 0 nothing (lane maps
## where hundreds die).
@export var loot_rate := 1.0

## Set by the map's FogOfWar; null when everyone sees everything.
var fog_of_war: FogOfWar
## The navigation map has synced with this map's navigation mesh. Until then path and
## closest-point queries answer from an empty map (after a scene change the world's map
## lives on, already past its first sync, but without the new map's regions).
var nav_ready := false

## Unit types in use; units store an index into this (UnitStore.definition_of).
var definitions: Array[UnitDefinition] = []

var _store := UnitStore.new()  ## made with the registry, so the fog of war can lay out before _ready
var _nodes: Dictionary[int, Unit] = {}  ## heroes and summons, by handle
var _attack_types: Dictionary[int, AttackType] = {}  ## by handle; none deals plain damage
var _dialogues: Dictionary[int, Dialogue] = {}  ## neutrals that can be talked to, by handle
var _last_talk: Dictionary[int, float] = {}  ## neutral -> when it was last talked to
var _drops: Dictionary[int, Array] = {}  ## handle -> items it drops when it dies (set_drops)
var _drop_gold: Dictionary[int, int] = {}  ## handle -> gold it drops when it dies
## Timed spell effects (noh states): handle -> id -> {time, source, stun, slow, dps, stacking, stacks}.
## Not saved, like other spell effects.
var _effects: Dictionary[int, Dictionary] = {}
# NPCs' engine-side parts, by the index in their handle
var _agents: Array[RID] = []
var _proxies: Array[Node3D] = []
var _proxy_anims: Array[AnimationPlayer] = []
var _proxy_pool: Dictionary[int, Array] = {}  ## definition -> hidden proxies
var _hero_count := 0
var _spawners: Array[CreepSpawner] = []  ## lane index -> its spawner
var _dying: Dictionary[int, bool] = {}  ## units being killed right now (_kill): no damage reaches them
var _bursts: Array[Dictionary] = []  ## champions' deaths about to go off (Fire Enchanted): at, team, time, modifier
var _aura_timer := 0.0
var _map: RID
var _rings: MultiMeshInstance3D
var _ring_buffer := PackedFloat32Array()
var _simulation_usec := 0
var _presentation_usec := 0


func _ready() -> void:
	add_to_group(GROUP)
	_store.name = &"Store"
	add_child(_store)
	_map = get_world_3d().navigation_map
	NavigationServer3D.map_changed.connect(_on_navigation_map_changed)
	_agents.resize(PER_KIND)
	_proxies.resize(PER_KIND)
	_proxy_anims.resize(PER_KIND)
	_create_rings()
	Simulation.join(self, Simulation.Order.UNITS)
	FrameMonitor.add(MONITOR_SIMULATION, func() -> float: return _simulation_usec / 1000.0)
	FrameMonitor.add(MONITOR_PRESENTATION, func() -> float: return _presentation_usec / 1000.0)
	FrameMonitor.add(MONITOR_ROWS, func() -> int:
		return _store.count_alive(Kind.HERO, -1) + _store.count_alive(Kind.NPC, -1) + _store.count_alive(Kind.SUMMON, -1))


func _on_navigation_map_changed(map: RID) -> void:
	# A sync can come before the map's baked mesh is in (the region joins with the mesh the scene
	# was saved with, often empty): closest-point queries would answer the origin until then
	if map == _map and NavigationServer3D.map_get_closest_point_owner(_map, Vector3.ZERO).is_valid():
		nav_ready = true
		_store.set_navigation_map(_map)
		var grid := WalkGrid.current
		if grid != null:
			_store.set_walk_grid(grid.origin, grid.size, WalkGrid.CELL, grid.cells)


func _exit_tree() -> void:
	for agent in _agents:
		if agent.is_valid():
			NavigationServer3D.free_rid(agent)
	for monitor in [MONITOR_SIMULATION, MONITOR_PRESENTATION, MONITOR_ROWS]:
		FrameMonitor.remove(monitor)


# --- Handles -------------------------------------------------------------------
# Accessors taking a handle answer a default (zero, NONE) for a unit that's gone; check
# is_alive first where it matters.

## The kind a handle's shape says (Kind), or -1 for NONE.
static func kind_of(handle: int) -> int:
	return (handle >> INDEX_BITS) & 7 if handle >= 0 else -1


static func index_of(handle: int) -> int:
	return handle & (PER_KIND - 1)


func life_of(handle: int) -> Life:
	return _store.life_of(handle) as Life


func is_alive(handle: int) -> bool:
	return handle >= 0 and _store.is_alive(handle)


func is_hero(handle: int) -> bool:
	return kind_of(handle) == Kind.HERO and life_of(handle) != Life.FREE


## Heroes and summons: the units with a node the player can order.
func is_player_unit(handle: int) -> bool:
	return kind_of(handle) != Kind.NPC and life_of(handle) != Life.FREE


## The node behind a hero or summon, else null.
func unit_of(handle: int) -> Unit:
	return _nodes.get(handle)


func definition_of(handle: int) -> UnitDefinition:
	return definitions[_store.definition_of(handle)]


func team_of(handle: int) -> int:
	return _store.team_of(handle)


func position_of(handle: int) -> Vector3:
	return _store.position_of(handle)


func yaw_of(handle: int) -> float:
	return _store.yaw_of(handle)


func radius_of(handle: int) -> float:
	return _store.radius_of(handle)


func height_of(handle: int) -> float:
	return _store.height_of(handle)


func health_of(handle: int) -> float:
	return _store.health_of(handle)


func max_health_of(handle: int) -> float:
	return _store.max_health_of(handle)


func evasion_of(handle: int) -> float:
	return _store.evasion_of(handle)


func parry_of(handle: int) -> float:
	return _store.parry_of(handle)


func spell_damage_of(handle: int) -> float:
	return _store.spell_damage_of(handle)


func is_stealthed(handle: int) -> bool:
	return _store.is_stealthed(handle)


func mana_regen_bonus_of(handle: int) -> float:
	return _store.mana_regen_bonus_of(handle)


## The unit an NPC is after, or NONE.
func target_of(handle: int) -> int:
	return _store.target_of(handle)


## An NPC's lane (index of its spawner); -1: it stands still.
func lane_of(handle: int) -> int:
	return _store.lane_of(handle)


## Makes an NPC stand where it is from now on (tests, scripted scenes).
func hold_position(handle: int) -> void:
	_store.set_lane_of(handle, -1)


## Slides a creep or neutral by `offset` along the ground (Maren's pearl pulling them in), drawn
## sliding, not jumping; not into what can't be walked. Heroes and summons move themselves.
func drag(handle: int, offset: Vector3) -> void:
	if not is_alive(handle) or kind_of(handle) != Kind.NPC:
		return
	var at := _store.position_of(handle) + Vector3(offset.x, 0.0, offset.z)
	if WalkGrid.current != null and not WalkGrid.current.is_walkable(at):
		return
	_store.set_position(handle, at)


## Puts a unit somewhere at once (scripted scenes and tests; units walk otherwise): it's drawn
## there at once too, not slid over from where it was.
func place(handle: int, at: Vector3, yaw := NAN) -> void:
	_store.teleport(handle, at, _store.yaw_of(handle) if is_nan(yaw) else yaw)


## Where shots fly to: chest height of the drawn unit (on top of the terrain).
func aim_point(handle: int) -> Vector3:
	return Terrain.lift(_store.position_of(handle)) + Vector3.UP * _store.height_of(handle) * 0.6


func edge_distance(from: int, to: int) -> float:
	return _store.edge_distance(from, to)


## Whether units of `team` see the unit `handle` (noh IUnitEntity::CanSee): their own side
## always; neutrals have no sight of their own and see everyone.
func can_see(team: int, handle: int) -> bool:
	return life_of(handle) != Life.FREE and _store.sees(team, handle)


## Whether the player sees the unit `handle` (noh CPlayer::CanSee): drawn, pickable, targetable.
func player_sees(handle: int) -> bool:
	return can_see(player_team, handle)


## Game time of the registry's simulation.
func now() -> float:
	return _store.now()


## When `handle` last attacked a unit of `team` (noh GetLastAggression), -INF if never.
func last_aggression(handle: int, team: int) -> float:
	return _store.last_aggression(handle, team)


## Teams that fight each other: different teams, neither of them neutral.
static func are_enemies(team_a: int, team_b: int) -> bool:
	return team_a != team_b and team_a != NEUTRAL_TEAM and team_b != NEUTRAL_TEAM


## Whether a unit of `other_team` with these sight bits shows to `team` (see can_see).
static func sees_bits(team: int, other_team: int, sighted: int) -> bool:
	return team == NEUTRAL_TEAM or other_team == team or (sighted & (1 << team)) != 0


func is_neutral(handle: int) -> bool:
	return is_alive(handle) and _store.team_of(handle) == NEUTRAL_TEAM


## What a neutral NPC says, or null.
func dialogue_of(handle: int) -> Dialogue:
	return _dialogues.get(handle) if is_alive(handle) else null


## `speaker` talks to the neutral `npc`: it turns toward them and says its lines.
func talk(npc: int, speaker: int) -> void:
	if not is_neutral(npc):
		return
	_store.set_listening(npc, speaker)
	# Several selected heroes arriving together, or a quick double click: one talk
	if now() - _last_talk.get(npc, -INF) < TALK_REPEAT_TIME:
		return
	_last_talk[npc] = now()
	talked_to.emit(npc, speaker)


## The NPC said all its lines to `speaker` (DialogueOverlay).
func finish_dialogue(npc: int, speaker: int) -> void:
	dialogue_finished.emit(npc, speaker)


## The NPC stops turning toward whoever talked to it.
func stop_listening(npc: int) -> void:
	_store.set_listening(npc, NONE)


func relation_color(handle: int) -> Color:
	return _relation_color(_store.team_of(handle), kind_of(handle))


func _relation_color(team: int, kind: int) -> Color:
	if team == NEUTRAL_TEAM:
		return Commander.COLOR_NEUTRAL
	if team != player_team:
		return Commander.COLOR_ENEMY
	return Commander.COLOR_ALLY if kind == Kind.NPC else Commander.COLOR_OWN


## Handles of the living units of `kind` (every kind with -1), or of the fallen ones (dying
## NPCs, fallen heroes). For one kind they come in the order of that kind's columns.
func handles(kind := -1, fallen := false) -> PackedInt64Array:
	if kind >= 0:
		return _store.handles(kind, fallen)
	var all := PackedInt64Array()
	for each in KINDS:
		all.append_array(_store.handles(each, fallen))
	return all


## One field of a kind's living (or fallen) units, in handles(kind) order: one call a frame
## instead of one per unit. Names: UnitStore's (position, velocity, desired, route.home...).
func vec3_column(kind: Kind, column: String, fallen := false) -> PackedVector3Array:
	return _store.vec3_column(kind, fallen, column)


## Where to draw a kind's living (or fallen) units this frame, in handles(kind) order: creeps
## between their last two ticks (Simulation.alpha), heroes and summons where their bodies are.
func display_positions(kind: Kind, fallen := false) -> PackedVector3Array:
	return _store.display_positions(kind, fallen, Simulation.alpha)


## yaw, radius, health, max_health, look.height, look.scale, look.flash_time, swing.time...
func float_column(kind: Kind, column: String, fallen := false) -> PackedFloat32Array:
	return _store.float_column(kind, fallen, column)


## team, definition, sighted, stealthed, look.highlight, target, anim, route.lane, anchored...
func int_column(kind: Kind, column: String, fallen := false) -> PackedInt64Array:
	return _store.int_column(kind, fallen, column)


## The fog of war's grid (FogOfWar._layout): `size` cells of `cell` meters from `origin`,
## padded by `pad` cells. The native core casts the teams' sight into it and works out every
## unit's sight bits.
func set_sight_layout(origin: Vector2, size: Vector2i, cell: float, pad: int) -> void:
	_store.set_sight_layout(origin, size, cell, pad)


## Per padded cell: the top of what blocks sight there (the occlusion map), and the ground.
func set_sight_occlusion(heights: PackedFloat32Array, ground: PackedFloat32Array) -> void:
	_store.set_sight_occlusion(heights, ground)


## noh's visibility update: every unit that sees casts its sight into its team's map, eyes
## `eye_height` above the ground; the finished maps replace the last ones.
func update_fog(eye_height: float) -> void:
	_store.update_fog(eye_height, player_team)


## A copy of a team's last finished map (one byte per padded cell, non-zero: seen).
func sight_map(team: int) -> PackedByteArray:
	return _store.sight_map(team)


## One unit's sight bits from the current maps (update_sight does every unit's).
func sight_bits_of(handle: int, enabled: bool, aggression_time: float) -> int:
	return _store.sight_bits_of(handle, enabled, aggression_time)


## noh's "update sight flags" pass over every unit, in the native core (FogOfWar.sight_bits does
## one unit). `enabled` false: everyone sees everyone.
func update_sight(enabled: bool, aggression_time: float) -> void:
	_store.update_sight(enabled, aggression_time)


func count_alive(kind: Kind, team := -1) -> int:
	return _store.count_alive(kind, team)


func spawner_for_team(team: int) -> CreepSpawner:
	for node in get_tree().get_nodes_in_group(&"creep_spawners"):
		if node.team == team:
			return node
	return null


# --- Units coming and going ----------------------------------------------------

## Registers a hero node; at most MAX_HEROES heroes ever exist.
func add_hero(unit: Unit) -> int:
	if not unit.ai and _hero_count >= MAX_HEROES:
		push_error("Hero limit of %d reached, %s not added" % [MAX_HEROES, unit.definition.display_name])
		return NONE
	var handle := _add_node(unit, Kind.HERO)
	if handle != NONE and not unit.ai:
		_hero_count += 1  # computer-controlled heroes (HeroBrain) don't count
	return handle


## Takes a hero node off the registry for good (a computer-controlled hero's body fading).
func remove_node(handle: int) -> void:
	if kind_of(handle) == Kind.NPC or life_of(handle) == Life.FREE:
		return
	if kind_of(handle) == Kind.HERO and not _nodes[handle].ai:
		_hero_count -= 1
	_nodes.erase(handle)
	_free(handle)


## Registers a summoned unit node; summons don't count towards the hero limit.
func add_summon(unit: Unit) -> int:
	return _add_node(unit, Kind.SUMMON)


func sync_unit(handle: int, at: Vector3, yaw: float) -> void:
	_store.set_position(handle, at)
	_store.set_yaw(handle, yaw)


## The nearest walkable ground to `at`: from the map's WalkGrid, or the navigation map.
func _walkable_spot(at: Vector3) -> Vector3:
	var spot := WalkGrid.current.nearest_walkable(at) if WalkGrid.current != null else Vector3.INF
	if spot == Vector3.INF:
		spot = NavigationServer3D.map_get_closest_point(_map, at)
	return Vector3(spot.x, at.y, spot.z)


func spawn_npc(definition: UnitDefinition, team: int, at: Vector3, spawner: CreepSpawner) -> int:
	# A spawn spot inside an obstacle moves to the nearest walkable ground
	if nav_ready:
		at = _walkable_spot(at)
	# As authored, it takes the map's level, and maybe a champion's modifiers (a raised corpse keeps its own)
	if definition.monster_level == 0:
		var level := monster_level + spawner.level_bonus
		definition = definition.leveled(level, spawner.next_modifiers(level))
	var size := spawner.creep_scale * (CHAMPION_SCALE if definition.is_champion() else 1.0)
	var handle := _create(Kind.NPC, definition, team, at, spawner.lane_yaw(), size)
	if handle == NONE:
		push_warning("Unit registry full, creep not spawned")
		return NONE
	_store.start_npc(handle, _lane_of_spawner(spawner), at, randf() * BEHAVIOR_UPDATE_TIME)  # spread target scans over frames
	_attach_agent(handle, definition)
	_attach_proxy(handle)
	return handle


## A neutral NPC standing at `at`, facing `yaw`, saying `dialogue` when talked to.
func spawn_neutral(definition: UnitDefinition, at: Vector3, yaw: float, dialogue: Dialogue = null, model_scale := 1.0,
		can_be_hurt := false) -> int:
	if nav_ready:
		at = _walkable_spot(at)
	var handle := _create(Kind.NPC, definition, NEUTRAL_TEAM, at, yaw, model_scale)
	if handle == NONE:
		push_warning("Unit registry full, %s not spawned" % definition.display_name)
		return NONE
	_store.start_npc(handle, -1, at, 0.0)
	_attach_agent(handle, definition)
	_attach_proxy(handle)
	_store.set_invulnerable(handle, not can_be_hurt)
	if dialogue != null:
		_dialogues[handle] = dialogue
	return handle


## The lane index of a spawner, telling the native core its lane nodes the first time.
func _lane_of_spawner(spawner: CreepSpawner) -> int:
	var lane := _spawners.find(spawner)
	if lane < 0:
		lane = _spawners.size()
		_spawners.append(spawner)
		_send_lane(lane)
	return lane


func _send_lane(lane: int) -> void:
	var spawner := _spawners[lane]
	var points := PackedVector3Array()
	for node in spawner.lane_nodes:
		points.append(node.global_position)
	_store.set_lane(lane, spawner.global_position, points)


func _add_node(unit: Unit, kind: Kind) -> int:
	var handle := _create(kind, unit.definition, unit.team, unit.global_position, unit.rotation.y)
	if handle == NONE:
		push_warning("Unit registry full, %s not added" % unit.definition.display_name)
		return NONE
	_nodes[handle] = unit
	return handle


func _create(kind: Kind, definition: UnitDefinition, team: int, at: Vector3, yaw: float, model_scale := 1.0) -> int:
	var handle: int = _store.add_unit(kind, team, _type_of(definition), at, yaw, definition.radius * model_scale,
			definition.height * model_scale, model_scale, definition.max_health, definition.armor, definition.armor_type)
	if handle == NONE:
		return NONE
	if definition.attack_type != null:
		_attack_types[handle] = definition.attack_type
	_store.set_sighted(handle, fog_of_war.sight_bits(handle) if fog_of_war != null else FogOfWar.ALL_TEAMS)
	return handle


## The definition's index, telling the native core what its creep behavior needs the first time.
func _type_of(definition: UnitDefinition) -> int:
	var type := definitions.find(definition)
	if type < 0:
		type = definitions.size()
		definitions.append(definition)
		_define(type)
	return type


func _define(type: int) -> void:
	var d := definitions[type]
	_store.define(type, d.move_speed, d.aggro_range, d.attack_range, d.attack_point, d.attack_backswing,
			d.attack_cooldown, d.turn_rate, d.siege, d.sight_range, d.clear_vision)


func _kill(handle: int, killer: int) -> void:
	_dying[handle] = true
	_kill_now(handle, killer)
	_dying.erase(handle)


func _kill_now(handle: int, killer: int) -> void:
	_effects.erase(handle)
	if are_enemies(_store.team_of(handle), player_team):
		_award_experience(handle, killer)
	var slayer := unit_of(killer) if killer != NONE else null
	if slayer != null and slayer.handle == killer:
		slayer.say(&"kill")
		slayer.on_kill(handle, _store.position_of(handle))  # its items' powers (the Ashen Harrow's burst)
	unit_died.emit(handle, killer)
	match kind_of(handle):
		Kind.HERO:
			_store.fall(handle, 0.0)  # its body stays until revived
			_nodes[handle].on_killed()
		Kind.SUMMON:
			# Summons leave no corpse; the node fades out on its own
			var unit: Unit = _nodes[handle]
			_nodes.erase(handle)
			_free(handle)
			unit.on_killed()
		Kind.NPC:
			_roll_loot(handle)
			_spill_drops(handle)
			_start_bursts(handle)
			_store.fall(handle, DYING_TIME)
			NavigationServer3D.agent_set_map(_agents[index_of(handle)], RID())


# --- Champions (DIRECTION.md 2: MonsterModifier) ---------------------------------

func _hits_with_modifiers(definition: UnitDefinition) -> bool:
	for modifier in definition.modifiers:
		if modifier.acts_on_hit():
			return true
	return false


## A champion's hit landed on `victim` for `damage`: what its modifiers add (chill, life steal, mana burn).
func _champion_hit(victim: int, source: int, damage: float) -> void:
	if life_of(source) == Life.FREE:
		return
	for modifier in definition_of(source).modifiers:
		if modifier.chill > 0.0 and is_alive(victim):
			add_effect(victim, &"chilled", modifier.chill_time, source, {"slow": modifier.chill, "attack_slow": modifier.chill * 0.5})
			flash(victim, ELEMENT_COLORS[&"ice"])
		if modifier.life_steal > 0.0 and is_alive(source):
			_store.set_health(source, minf(_store.health_of(source) + damage * modifier.life_steal, _store.max_health_of(source)))
		if modifier.mana_burn > 0.0 and is_alive(victim) and _nodes.has(victim):
			var unit := _nodes[victim]
			unit.mana = maxf(unit.mana - modifier.mana_burn, 0.0)


## A champion fell: its death modifiers (Fire Enchanted) mark the ground, and go off a moment later.
func _start_bursts(handle: int) -> void:
	for modifier in definition_of(handle).modifiers:
		if modifier.death_damage <= 0.0:
			continue
		var at := _store.position_of(handle)
		_bursts.append({"at": at, "team": _store.team_of(handle), "time": modifier.death_delay, "modifier": modifier})
		SpellEffects.pulse(get_parent(), Terrain.lift(at), modifier.death_radius, ELEMENT_COLORS.get(modifier.death_element, Color.ORANGE),
				modifier.death_delay)


func _update_bursts(delta: float) -> void:
	for i in range(_bursts.size() - 1, -1, -1):
		var burst := _bursts[i]
		burst.time -= delta
		if burst.time > 0.0:
			continue
		_bursts.remove_at(i)
		var modifier: MonsterModifier = burst.modifier
		var color: Color = ELEMENT_COLORS.get(modifier.death_element, Color.ORANGE)
		SpellEffects.pillar(get_parent(), Terrain.lift(burst.at), color, modifier.death_radius * 0.6, 3.0, 0.5)
		Sounds.play_at(modifier.death_element, burst.at)
		for victim in query_radius(burst.at, modifier.death_radius):
			if are_enemies(_store.team_of(victim), burst.team):
				apply_damage(victim, modifier.death_damage, NONE, false)


## A monster of the player's enemies fell: what it drops (LootRoller), on top of what it was given
## to drop (set_drops).
func _roll_loot(handle: int) -> void:
	if loot_rate <= 0.0 or not are_enemies(_store.team_of(handle), player_team):
		return
	var loot := LootRoller.drops_for(definition_of(handle), loot_rate)
	if not loot.items.is_empty():
		var items: Array = _drops.get(handle, []).duplicate()
		items.append_array(loot.items)
		_drops[handle] = items
	if loot.gold > 0:
		_drop_gold[handle] = _drop_gold.get(handle, 0) + loot.gold


## The unit `handle` died: its drops land around where it fell.
func _spill_drops(handle: int) -> void:
	var items: Array = _drops.get(handle, [])
	var gold: int = _drop_gold.get(handle, 0)
	_drops.erase(handle)
	_drop_gold.erase(handle)
	var count := items.size() + (1 if gold > 0 else 0)
	var at := _store.position_of(handle)
	for i in count:
		var offset := Vector3.FORWARD.rotated(Vector3.UP, TAU * i / count) * (0.8 if count > 1 else 0.0)
		if i < items.size():
			ItemPickup.drop(get_parent(), items[i], at + offset)
		else:
			ItemPickup.drop_gold(get_parent(), gold, at + offset)


## Takes a neutral or creep off the map at once, without a death or a corpse (a villager who
## joins the party as a hero).
func despawn(handle: int) -> void:
	if kind_of(handle) != Kind.NPC or life_of(handle) == Life.FREE:
		return
	var index := index_of(handle)
	if _proxies[index] != null:
		_release_proxy(handle)
	if _agents[index].is_valid():
		NavigationServer3D.agent_set_map(_agents[index], RID())
	_free(handle)


## The death animation is over: leave a corpse marker and free the index.
func _bury(handle: int) -> void:
	if corpses != null:
		corpses.add(_store.position_of(handle), _store.yaw_of(handle), _store.team_of(handle), definition_of(handle),
				_store.scale_of(handle))
	_release_proxy(handle)
	_free(handle)


func _free(handle: int) -> void:
	_effects.erase(handle)
	_dialogues.erase(handle)
	_last_talk.erase(handle)
	_drops.erase(handle)
	_drop_gold.erase(handle)
	_attack_types.erase(handle)
	_store.release(handle)


## Warcraft III style: the heroes of the killing side near the death split the bounty.
func _award_experience(handle: int, _killer: int) -> void:
	var bounty := definition_of(handle).bounty_experience * experience_rate
	var team := _store.team_of(handle)
	var at := _store.position_of(handle)
	var receivers: Array[Unit] = []
	for other: int in _nodes:
		if kind_of(other) == Kind.HERO and is_alive(other) and are_enemies(_store.team_of(other), team) \
				and _store.position_of(other).distance_to(at) <= EXPERIENCE_RANGE and not _nodes[other].ai:
			receivers.append(_nodes[other])  # computer-controlled heroes level with the party instead
	for hero in receivers:
		hero.add_experience(bounty / receivers.size())


# --- Combat --------------------------------------------------------------------

## Attacks are physical: they can be evaded or parried, and armor takes a flat amount off
## every hit, never below Stats.MIN_DAMAGE (StarCraft). Spells pass physical = false: they
## ignore all three and grow with the caster's spell damage. A physical spell (Decapitate,
## Whirling Blade) passes evadable = false: armor counts, evasion and parries don't.
## True when it hurt.
func apply_damage(victim: int, amount: float, source: int, physical := true, evadable := true) -> bool:
	if god_team >= 0 and is_alive(victim) and _store.team_of(victim) == god_team:
		return false
	if not is_alive(victim) or _store.is_invulnerable(victim) or _dying.has(victim):
		return false  # (a unit being killed is still alive until its body falls: what its death sets off can't kill it again)
	var npc := kind_of(victim) == Kind.NPC
	if physical:
		var evasion := _store.evasion_of(victim)
		if evadable and evasion > 0.0 and randf() * 100.0 < evasion:
			attack_evaded.emit(victim)
			return false
		var parry := _store.parry_of(victim)
		if evadable and parry > 0.0 and randf() * 100.0 < parry:
			attack_parried.emit(victim, source)
			Sounds.play_at(&"clunk", _store.position_of(victim))
			if not npc:
				_nodes[victim].on_parried(source)
			return false
		amount = maxf(amount - _store.armor_of(victim) - _store.armor_bonus_of(victim), Stats.MIN_DAMAGE)
	elif life_of(source) != Life.FREE:
		amount *= 1.0 + _store.spell_damage_of(source) / 100.0
	if not npc:
		amount *= _nodes[victim].damage_taken  # illusions (Reflection) take extra
	var health := _store.health_of(victim) - amount
	_store.set_health(victim, health)
	if health <= 0.0:
		_kill(victim, source)
	elif not npc:
		_nodes[victim].on_damaged(source)
	else:
		_store.npc_damaged(victim, source)  # a camp rouses; a creep turns on an attacker it sees
	return true


## Items (and gold) the unit `handle` drops when it dies, e.g. a quest item on a scripted ambusher:
##     registry.set_drops(registry.spawn_npc(...), [preload("res://data/items/...tres")], 25)
func set_drops(handle: int, items: Array, gold := 0) -> void:
	if life_of(handle) == Life.FREE:
		return
	if items.is_empty():
		_drops.erase(handle)
	else:
		_drops[handle] = items.duplicate()
	if gold > 0:
		_drop_gold[handle] = gold
	else:
		_drop_gold.erase(handle)


func drops_of(handle: int) -> Array:
	return _drops.get(handle, [])


## A fallen hero gets up again with `health_share` of its health (Unit.revive).
func revive(handle: int, health_share: float) -> void:
	if life_of(handle) != Life.DEAD:
		return
	_store.rise(handle, maxf(_store.max_health_of(handle) * health_share, 1.0))


## Ends a unit's life outright, e.g. a summon whose time ran out.
func kill(handle: int) -> void:
	if is_alive(handle):
		_kill(handle, NONE)


func heal(target: int, amount: float) -> void:
	if is_alive(target):
		_store.set_health(target, minf(_store.health_of(target) + amount, _store.max_health_of(target)))


## A new maximum health (hero stats changed); the unit keeps the same share of it.
func set_max_health(handle: int, value: float) -> void:
	var old := _store.max_health_of(handle)
	var share := _store.health_of(handle) / old if old > 0.0 else 1.0
	_store.set_max_health(handle, value)
	if is_alive(handle):
		_store.set_health(handle, maxf(share * value, 1.0))


## A hero's or summon's armor, evasion, parry, spell damage and attack type, worked out
## from its stats and items.
func set_combat_stats(handle: int, armor: float, evasion: float, parry: float, spell_damage: float, attack_type: AttackType) -> void:
	_store.set_combat(handle, armor, evasion, parry, spell_damage)
	if attack_type != null:
		_attack_types[handle] = attack_type
	else:
		_attack_types.erase(handle)


## Stealth: other teams can't see the unit until it ends (FogOfWar.sight_bits).
func set_stealth(handle: int, value: bool) -> void:
	if life_of(handle) == Life.FREE:
		return
	_store.set_stealthed(handle, value)
	if fog_of_war != null:
		_store.set_sighted(handle, fog_of_war.sight_bits(handle))


func set_invulnerable(handle: int, value: bool) -> void:
	_store.set_invulnerable(handle, value)


# --- Spell effects on units (noh states) ---------------------------------------

## Puts the timed effect `id` on `handle` for `seconds`, or refreshes it. `fields` say what
## it does: "stun" (true: can't move, attack or cast), "slow" (share of move speed taken,
## 0..1), "dps" (magic damage per second from `source`), "stacking" (true: every
## application adds a stack and dps counts per stack), "damage_dealt" (its attacks' damage
## is multiplied by it: Terrified 0.5). Returns the effect, or {} when the unit is gone.
func add_effect(handle: int, id: StringName, seconds: float, source: int, fields: Dictionary) -> Dictionary:
	if not is_alive(handle):
		return {}
	if not _effects.has(handle):
		_effects[handle] = {}
	var effect: Dictionary = _effects[handle].get(id, {"stacks": 0})
	effect.merge(fields, true)
	effect.time = seconds
	effect.source = source
	effect.stacks = effect.stacks + 1 if effect.get("stacking", false) else 1
	_effects[handle][id] = effect
	_push_status(handle)
	return effect


func is_stunned(handle: int) -> bool:
	return _stunned(handle)


## The largest slow on `handle`, as a share of its move speed (0..1).
func slow_of(handle: int) -> float:
	return _slow(handle)


## The largest attack slow on `handle` (Brook's chill), as a share of its attack speed (0..1).
func attack_slow_of(handle: int) -> float:
	var slow := 0.0
	for effect: Dictionary in _effects.get(handle, {}).values():
		slow = maxf(slow, effect.get("attack_slow", 0.0))
	return minf(slow, 0.9)


func _stunned(handle: int) -> bool:
	for effect: Dictionary in _effects.get(handle, {}).values():
		if effect.get("stun", false):
			return true
	return false


func _slow(handle: int) -> float:
	var slow := 0.0
	for effect: Dictionary in _effects.get(handle, {}).values():
		slow = maxf(slow, effect.get("slow", 0.0))
	return minf(slow, 1.0)


## Tells the native core what an NPC's effects do to it (a stun cuts its swing short).
func _push_status(handle: int) -> void:
	if kind_of(handle) == Kind.NPC:
		_store.set_status(handle, _stunned(handle), _slow(handle), attack_slow_of(handle))


## Ticks effects down and deals their damage over time.
func _update_effects(delta: float) -> void:
	for handle: int in _effects.keys():
		var on: Dictionary = _effects.get(handle, {})
		var ended := false
		for id: StringName in on.keys():
			var effect: Dictionary = on[id]
			effect.time -= delta
			var dps: float = effect.get("dps", 0.0)
			if dps > 0.0:
				apply_damage(handle, dps * effect.stacks * delta, effect.source, false)
				if not _effects.has(handle):
					break  # it died
			if effect.time <= 0.0:
				on.erase(id)
				ended = true
		if _effects.has(handle) and on.is_empty():
			_effects.erase(handle)
		if ended:
			_push_status(handle)


## How far past its own attack range a melee blow still lands (edge to edge): farther, it misses (its target
## changed mid-swing, or ran out from under it). 150 HoN units.
const MELEE_REACH_BUFFER := 150.0 / RTSCamera.NOH_UNITS_PER_METER

## Hits `victim` with an attack from `source`: a projectile for ranged attackers. The
## attacker's attack type adds its bonus against the victim's armor type. Attacking shows
## the attacker to the victim's team for a moment (noh SetLastAggression).
## True when a melee hit landed (ranged attacks: when the projectile was launched); a melee blow out of
## reach (its attack range and MELEE_REACH_BUFFER) misses, told like an evasion. A real miss, not zero
## damage: nothing on it fires (on-hit powers, a champion's chill, the sound, the aggression).
## `on_hit(victim)` runs when the attack lands, on arrival for a projectile (Shadow Cripple).
func deliver_attack(source: int, victim: int, damage: float, definition: UnitDefinition, color := Color(0, 0, 0, 0),
		on_hit := Callable()) -> bool:
	if not definition.is_ranged() and is_alive(source) and is_alive(victim) \
			and edge_distance(source, victim) > attack_range_of(source, definition) + MELEE_REACH_BUFFER:
		attack_evaded.emit(victim)
		return false
	if life_of(source) != Life.FREE and life_of(victim) != Life.FREE:
		var victim_team := _store.team_of(victim)
		_store.set_aggression(source, victim_team, now())
		_store.set_sighted(source, _store.sighted_of(source) | (1 << victim_team))
		damage *= AttackType.multiplier_of(_attack_types.get(source), _store.armor_type_of(victim) as Stats.Armor)
		if kind_of(victim) != Kind.NPC:
			_nodes[victim].on_attacked(source)  # passives that answer attacks (Whirling Blade)
	if definition.is_ranged():
		Projectile.launch(self, source, victim, damage, definition.projectile_speed,
				color if color.a > 0.0 else definition.projectile_color, on_hit)
		return true
	var landed := apply_damage(victim, damage, source)
	if landed and on_hit.is_valid():
		on_hit.call(victim)
	return landed


## `source`'s attack range: a hero's own (it grows with items and passives: Eagle Eye), else its definition's.
func attack_range_of(source: int, definition: UnitDefinition) -> float:
	var node: Unit = _nodes.get(source)
	return node.attack_range() if node != null else definition.attack_range


## Base attack damage with the attacker's aura bonuses.
func attack_damage(handle: int, base: float) -> float:
	if definition_of(handle).is_ranged():
		base *= 1.0 + _store.ranged_bonus_of(handle)
	for effect: Dictionary in _effects.get(handle, {}).values():
		base *= effect.get("damage_dealt", 1.0)  # Terrified: half damage
	return base


## noh's forced attack order (Taunt): `victim` attacks `attacker` for `seconds`, whatever
## else it wanted; a hero can't be ordered or cast meanwhile.
func force_attack(victim: int, attacker: int, seconds: float) -> void:
	if not is_alive(victim) or not is_alive(attacker):
		return
	if kind_of(victim) == Kind.NPC:
		_store.force_attack(victim, attacker, seconds)
	else:
		_nodes[victim].taunt(attacker, seconds)


## noh CBAttack's aggro trigger and IUnitEntity::AggroCreeps, for every attack order.
## Ordering `attacker` to attack an enemy hero makes that hero's creeps around the attacker
## switch to the attacker for a moment (noh AggroCreeps: hero targets only; attacking a creep
## pulls nothing). Ordering an attack on a friendly unit instead makes the enemy creeps that
## are after the attacker look for someone else: the de-aggro. (The native core does it.)
func attack_order_aggro(attacker: int, target: int) -> void:
	_store.attack_order_aggro(attacker, target)


## The living NPCs `spawner` sent: its creeps, or a NeutralCamp's creatures.
func npcs_of(spawner: CreepSpawner) -> Array[int]:
	var found: Array[int] = []
	var lane := _spawners.find(spawner)
	if lane >= 0:
		found.assign(_store.npcs_of(lane))
	return found


## Nearest living enemy of `handle` it sees within `scan_range` (edge to edge).
func find_enemy(handle: int, scan_range: float) -> int:
	return _store.find_enemy(handle, scan_range)


## What the NPC `handle` would target right now (noh threat), or NONE.
func best_target(handle: int) -> int:
	return _store.best_target(handle)


func flash(handle: int, color: Color) -> void:
	if life_of(handle) == Life.FREE:
		return
	_store.flash(handle, color, 0.6)
	if kind_of(handle) != Kind.NPC:
		_nodes[handle].flash(color)


## Every hero's passive auras, applied to allies in range. Same-kind auras don't stack
## (Warcraft III), so each unit keeps the strongest of each.
func _update_auras() -> void:
	_store.clear_auras()
	for handle: int in _nodes:
		if not is_alive(handle):
			continue
		var unit: Unit = _nodes[handle]
		for aura in unit.active_auras():
			var ability: AuraAbility = aura.ability
			_store.apply_aura(_store.team_of(handle), _store.position_of(handle), ability.radius, ability.stat,
					ability.amount(aura.level))


# --- Queries for the commander -------------------------------------------------

func clear_highlights() -> void:
	_store.clear_highlights()


func set_highlight(handle: int, level: int) -> void:
	_store.raise_highlight(handle, level)


## Living units whose center lies within `radius` of `center`.
func query_radius(center: Vector3, radius: float) -> Array[int]:
	var found: Array[int] = []
	found.assign(_store.query_radius(center, radius))
	return found


## Living units the player sees whose aim point projects inside a screen rectangle.
func query_screen_rect(view: Camera3D, rect: Rect2) -> Array[int]:
	var found: Array[int] = []
	for kind in KINDS:
		var ids := _store.handles(kind, false)
		var positions := _store.vec3_column(kind, false, "position")
		var heights := _store.float_column(kind, false, "look.height")
		var teams := _store.int_column(kind, false, "team")
		var sighted := _store.int_column(kind, false, "sighted")
		for i in ids.size():
			if not sees_bits(player_team, teams[i], sighted[i]):
				continue
			var point := Terrain.lift(positions[i]) + Vector3.UP * heights[i] * 0.6
			if view.is_position_in_frustum(point) and rect.has_point(view.unproject_position(point)):
				found.append(ids[i])
	return found


## The living unit under a screen point, nearest to the camera. Each unit is treated
## as its projected upright capsule. Units whose body center is off screen can't be
## picked, so a creep just past the screen edge never steals a click; nor can units
## hidden in the fog.
func pick(view: Camera3D, screen_point: Vector2, ignore := NONE) -> int:
	var best := NONE
	var best_depth := INF
	var camera_right := view.global_basis.x
	for kind in KINDS:
		var ids := _store.handles(kind, false)
		var positions := _store.vec3_column(kind, false, "position")
		var heights := _store.float_column(kind, false, "look.height")
		var radii := _store.float_column(kind, false, "radius")
		var teams := _store.int_column(kind, false, "team")
		var sighted := _store.int_column(kind, false, "sighted")
		for i in ids.size():
			if ids[i] == ignore or not sees_bits(player_team, teams[i], sighted[i]):
				continue
			var feet := Terrain.lift(positions[i])
			var height := heights[i]
			if not view.is_position_in_frustum(feet + Vector3.UP * height * 0.5):
				continue
			var bottom := view.unproject_position(feet)
			var top := view.unproject_position(feet + Vector3.UP * height)
			var reach := bottom.distance_to(view.unproject_position(feet + camera_right * radii[i])) + PICK_SLOP
			if Geometry2D.get_closest_point_to_segment(screen_point, bottom, top).distance_to(screen_point) > reach:
				continue
			var depth := view.global_position.distance_squared_to(feet + Vector3.UP * height * 0.5)
			if depth < best_depth:
				best_depth = depth
				best = ids[i]
	return best


# --- Saving (STATS_AND_ITEMS.md / SAVES.md) -------------------------------------
# The stores as they are (UnitStore.save: each kind's arrays, column by column, and its table
# of indices and generations), so every handle stays valid across a save and a load, like
# noh's pooled entity indices across snapshots. The same bytes are what a network snapshot of
# the map would carry.

func save_state() -> Dictionary:
	var data := {
		"units": _store.save(),
		"definitions": SaveCodec.encode_resources(definitions),
		"spawners": PackedStringArray(),
		"attack_types": {},
		"dialogues": {},
		"drops": {},
		"drop_gold": _drop_gold.duplicate(),
	}
	for spawner in _spawners:
		data.spawners.append(str(get_path_to(spawner)))
	for handle: int in _attack_types:
		data.attack_types[handle] = SaveCodec.encode_resource(_attack_types[handle])
	for handle: int in _dialogues:
		data.dialogues[handle] = SaveCodec.encode_resource(_dialogues[handle])
	for handle: int in _drops:
		data.drops[handle] = SaveCodec.encode_resources(_drops[handle])
	return data


## Replaces every unit with saved ones. Hero and summon rows wait for their nodes, which
## the map recreates and attaches with adopt(); creeps and neutrals get their models back.
func load_state(data: Dictionary) -> void:
	_clear_rows()
	if not data.has("units") or not _store.load(data.units):
		push_error("This save's units come from an older layout of the unit registry and can't be loaded")
		return
	SaveCodec.decode_resources_into(data.definitions, definitions)
	for type in definitions.size():
		_define(type)
	_spawners.clear()
	for path: String in data.spawners:
		_spawners.append(get_node(path) as CreepSpawner)
		_send_lane(_spawners.size() - 1)
	for key: Variant in data.get("attack_types", {}):
		var attack_type := SaveCodec.decode_resource(data.attack_types[key]) as AttackType
		if attack_type != null:
			_attack_types[int(key)] = attack_type
	for key: Variant in data.get("dialogues", {}):
		_dialogues[int(key)] = SaveCodec.decode_resource(data.dialogues[key]) as Dialogue
	for key: Variant in data.get("drops", {}):
		var items := []
		SaveCodec.decode_resources_into(data.drops[key], items)
		_drops[int(key)] = items
	for key: Variant in data.get("drop_gold", {}):
		_drop_gold[int(key)] = data.drop_gold[key]
	for fallen in [false, true]:
		for handle in _store.handles(Kind.NPC, fallen):
			if not fallen:
				_attach_agent(handle, definition_of(handle))
			_attach_proxy(handle)
	_store.clear_highlights()
	if fog_of_war != null:
		for handle in handles(-1, false) + handles(-1, true):
			_store.set_sighted(handle, fog_of_war.sight_bits(handle))


## Attaches a restored hero or summon node to its saved row instead of making a new one.
func adopt(unit: Unit, handle: int) -> int:
	if kind_of(handle) == Kind.NPC or life_of(handle) == Life.FREE:
		push_error("No saved row for %s" % unit.definition.display_name)
		return NONE
	_nodes[handle] = unit
	if kind_of(handle) == Kind.HERO and not unit.ai:
		_hero_count += 1
	return handle


## The hero and summon nodes on the map.
func unit_nodes() -> Array[Unit]:
	var units: Array[Unit] = []
	units.assign(_nodes.values())
	return units


func set_health(handle: int, value: float) -> void:
	if is_alive(handle):
		_store.set_health(handle, clampf(value, 1.0, _store.max_health_of(handle)))


func _clear_rows() -> void:
	for index in PER_KIND:
		if _proxies[index] != null:
			_proxies[index].visible = false
			if _proxy_anims[index] != null:
				_proxy_anims[index].stop()
			_proxies[index] = null
			_proxy_anims[index] = null
		if _agents[index].is_valid():
			NavigationServer3D.agent_set_map(_agents[index], RID())
	for unit in unit_nodes():
		unit.queue_free()
	_store.clear_all()
	_nodes.clear()
	_attack_types.clear()
	_dialogues.clear()
	_last_talk.clear()
	_drops.clear()
	_drop_gold.clear()
	_effects.clear()
	_hero_count = 0


# --- The simulation tick -------------------------------------------------------

func _simulate(delta: float) -> void:
	if not nav_ready:
		return
	var started := Time.get_ticks_usec()
	if not _effects.is_empty():
		_update_effects(delta)
	_aura_timer -= delta
	if _aura_timer <= 0.0:
		_aura_timer = AURA_UPDATE_TIME
		_update_auras()

	# The native core moves the creeps and thinks for them, asks the NavigationServer for paths
	# (several at once, on threads), and tells their avoidance agents where they're going
	_store.step(delta)

	# Then the game's rules on what happened: swings that landed, bodies to bury
	var sources := _store.landed_sources()
	var targets := _store.landed_targets()
	for i in sources.size():
		if is_alive(sources[i]) and is_alive(targets[i]):
			var definition := definition_of(sources[i])
			var damage := attack_damage(sources[i], definition.attack_damage)
			var on_hit := _champion_hit.bind(sources[i], damage) if _hits_with_modifiers(definition) else Callable()
			deliver_attack(sources[i], targets[i], damage, definition, Color(0, 0, 0, 0), on_hit)
	_update_bursts(delta)
	for handle in _store.buried():
		_bury(handle)
	_simulation_usec = Time.get_ticks_usec() - started


func _process(_delta: float) -> void:
	var started := Time.get_ticks_usec()
	_update_proxies()
	_update_rings()
	_presentation_usec = Time.get_ticks_usec() - started


func _attach_agent(handle: int, definition: UnitDefinition) -> void:
	var index := index_of(handle)
	var agent := _agents[index]
	if not agent.is_valid():
		agent = NavigationServer3D.agent_create()
		_agents[index] = agent
		NavigationServer3D.agent_set_neighbor_distance(agent, 6.0)
		NavigationServer3D.agent_set_max_neighbors(agent, 12)
		NavigationServer3D.agent_set_time_horizon_agents(agent, 0.8)
	NavigationServer3D.agent_set_avoidance_callback(agent, _store.avoided.bind(handle))  # straight into the store, this life's handle
	_store.set_agent(handle, agent)
	NavigationServer3D.agent_set_radius(agent, _store.radius_of(handle))
	NavigationServer3D.agent_set_height(agent, _store.height_of(handle))
	NavigationServer3D.agent_set_max_speed(agent, definition.move_speed)
	NavigationServer3D.agent_set_position(agent, _store.position_of(handle))
	NavigationServer3D.agent_set_velocity_forced(agent, Vector3.ZERO)
	NavigationServer3D.agent_set_avoidance_enabled(agent, true)
	NavigationServer3D.agent_set_map(agent, _map)


# --- Presentation --------------------------------------------------------------

func _attach_proxy(handle: int) -> void:
	var type := _store.definition_of(handle)
	var pool: Array = _proxy_pool.get(type, [])
	var proxy: Node3D
	if pool.is_empty():
		proxy = definitions[type].model.instantiate()
		add_child(proxy)
		# Characters animate; a prop standing for a unit (the ledger, a weir) has no skeleton to move
		if not proxy.find_children("*", "Skeleton3D", true, false).is_empty():
			var player := UnitAnimations.attach(proxy)
			proxy.set_meta(&"animation", player)
			# Off screen, or hidden in the fog: its animation stops (the renderer's culling tells)
			var enabler := VisibleOnScreenEnabler3D.new()
			enabler.aabb = PROXY_SCREEN_BOX
			enabler.enable_mode = VisibleOnScreenEnabler3D.ENABLE_MODE_INHERIT
			# Its target before it enters the tree: entering, it switches off whatever it points at,
			# by default its parent (the whole proxy), and pointing it elsewhere later never undoes that
			enabler.enable_node_path = NodePath("../" + String(proxy.get_path_to(player)))
			proxy.add_child(enabler)
	else:
		proxy = pool.pop_back()
		proxy.visible = true
	proxy.scale = Vector3.ONE * _store.scale_of(handle)
	var index := index_of(handle)
	_proxies[index] = proxy
	_proxy_anims[index] = proxy.get_meta(&"animation") if proxy.has_meta(&"animation") else null
	_store.set_anim(handle, Anim.NONE)


func _release_proxy(handle: int) -> void:
	var index := index_of(handle)
	var proxy := _proxies[index]
	if proxy == null:
		return
	proxy.visible = false
	if _proxy_anims[index] != null:
		_proxy_anims[index].stop()
	var type := _store.definition_of(handle)
	if not _proxy_pool.has(type):
		_proxy_pool[type] = []
	_proxy_pool[type].append(proxy)
	_proxies[index] = null
	_proxy_anims[index] = null


## Moves the creep models to their units and keeps their animation in step.
func _update_proxies() -> void:
	for fallen in [false, true]:
		var ids := _store.handles(Kind.NPC, fallen)
		var positions := _store.display_positions(Kind.NPC, fallen, Simulation.alpha)  # between the last two ticks
		var yaws := _store.display_yaws(Kind.NPC, fallen, Simulation.alpha)
		var velocities := _store.vec3_column(Kind.NPC, fallen, "velocity")
		var swings := _store.float_column(Kind.NPC, fallen, "swing.time")
		var teams := _store.int_column(Kind.NPC, fallen, "team")
		var sighted := _store.int_column(Kind.NPC, fallen, "sighted")
		var anims := _store.int_column(Kind.NPC, fallen, "anim")
		var types := _store.int_column(Kind.NPC, fallen, "definition")
		for i in ids.size():
			var index := index_of(ids[i])
			var proxy := _proxies[index]
			if proxy == null:
				continue
			proxy.visible = sees_bits(player_team, teams[i], sighted[i])  # the player only sees what their team sees
			proxy.position = Terrain.lift(positions[i])
			proxy.rotation.y = yaws[i]

			var animation := _proxy_anims[index]
			if animation == null:
				continue  # a prop: nothing to animate
			var speed := Vector2(velocities[i].x, velocities[i].z).length()
			var wanted := Anim.IDLE
			if fallen:
				wanted = Anim.DEATH
			elif swings[i] >= 0.0:
				wanted = Anim.ATTACK
			elif speed > 0.4:
				wanted = Anim.RUN
			if wanted == Anim.RUN:
				animation.speed_scale = clampf(speed / RUN_ANIMATION_SPEED, 0.6, 1.4)
			if wanted == anims[i]:
				continue
			_store.set_anim(ids[i], wanted)
			var definition := definitions[types[i]]
			match wanted:
				Anim.IDLE:
					animation.speed_scale = 1.0
					animation.play(&"general/Idle_A", 0.2)
				Anim.RUN:
					animation.play(&"move/Running_A", 0.15)
				Anim.ATTACK:
					var clip_length := animation.get_animation(definition.attack_animation).length
					animation.speed_scale = clip_length / (definition.attack_point + definition.attack_backswing)
					animation.play(definition.attack_animation, 0.08)
					animation.seek(0.0, true)
				Anim.DEATH:
					animation.speed_scale = 1.0
					animation.play(&"general/Death_A", 0.1)


func _create_rings() -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.62
	mesh.outer_radius = 0.72
	mesh.rings = 48
	mesh.ring_segments = 4
	var material := ShaderMaterial.new()
	material.shader = GROUND_DECAL  # follows the terrain under each ring
	material.set_shader_parameter(&"use_instance_color", true)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = mesh
	multimesh.instance_count = PER_KIND
	multimesh.visible_instance_count = 0
	_rings = MultiMeshInstance3D.new()
	_rings.multimesh = multimesh
	_rings.material_override = material
	_rings.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_rings)
	_ring_buffer.resize(PER_KIND * FLOATS_PER_INSTANCE)


## Creeps always show a faint team ring, brighter when hovered or selected. Heroes
## and summons draw their own ring; they only get told their highlight.
func _update_rings() -> void:
	for kind in [Kind.HERO, Kind.SUMMON]:
		var ids := _store.handles(kind, false)
		var levels := _store.int_column(kind, false, "look.highlight")
		var sides := _store.int_column(kind, false, "team")
		var sight := _store.int_column(kind, false, "sighted")
		for i in ids.size():
			var unit: Unit = _nodes.get(ids[i])
			if unit == null:
				continue
			unit.visible = sees_bits(player_team, sides[i], sight[i])
			unit.set_highlight(levels[i] == HIGHLIGHT_SELECTED, levels[i] == HIGHLIGHT_HOVER, _relation_color(sides[i], kind))

	var count := 0
	var positions := _store.display_positions(Kind.NPC, false, Simulation.alpha)
	var radii := _store.float_column(Kind.NPC, false, "radius")
	var flash_times := _store.float_column(Kind.NPC, false, "look.flash_time")
	var flash_colors := _store.color_column(Kind.NPC, false)
	var highlights := _store.int_column(Kind.NPC, false, "look.highlight")
	var teams := _store.int_column(Kind.NPC, false, "team")
	var sighted := _store.int_column(Kind.NPC, false, "sighted")
	for i in positions.size():
		if not sees_bits(player_team, teams[i], sighted[i]):
			continue
		var selected := highlights[i] == HIGHLIGHT_SELECTED
		var hovered := highlights[i] == HIGHLIGHT_HOVER
		var blink := flash_times[i] > 0.0 and fmod(flash_times[i], 0.2) > 0.1
		var color := flash_colors[i] if blink else _relation_color(teams[i], Kind.NPC)
		color.a = 1.0 if selected or blink else (0.7 if hovered else 0.3)
		var size := (radii[i] + 0.2) / RING_MESH_RADIUS
		var origin := positions[i] + Vector3.UP * 0.05
		var at := count * FLOATS_PER_INSTANCE
		_ring_buffer[at + 0] = size
		_ring_buffer[at + 1] = 0.0
		_ring_buffer[at + 2] = 0.0
		_ring_buffer[at + 3] = origin.x
		_ring_buffer[at + 4] = 0.0
		_ring_buffer[at + 5] = 0.25
		_ring_buffer[at + 6] = 0.0
		_ring_buffer[at + 7] = origin.y
		_ring_buffer[at + 8] = 0.0
		_ring_buffer[at + 9] = 0.0
		_ring_buffer[at + 10] = size
		_ring_buffer[at + 11] = origin.z
		_ring_buffer[at + 12] = color.r
		_ring_buffer[at + 13] = color.g
		_ring_buffer[at + 14] = color.b
		_ring_buffer[at + 15] = color.a
		count += 1
	_rings.multimesh.buffer = _ring_buffer
	_rings.multimesh.visible_instance_count = count
