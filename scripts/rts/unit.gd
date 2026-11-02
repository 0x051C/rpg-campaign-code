class_name Unit
extends CharacterBody3D

## A unit the player commands: a hero (UnitRegistry allows three) or a summon with a
## timed life. Player units run an order queue like noh's CBrain behavior deque
## (src/hon_shared/c_brain.cpp: QUEUE_NONE replaces the queue, QUEUE_BACK appends),
## move with a NavigationAgent3D and mirror into the UnitRegistry every physics
## frame, so creeps see, target and damage them through the same handles as anyone.
## Heroes level up from kills and cast DotaCraft spells: a cast walks into range,
## waits for the cast point, then channels until done or interrupted by a new order.
## Idle units guard their spot like noh's CBGuard. A fallen hero's body stays where
## it fell; only creep corpses decay.
##
## Stats come from a StatSheet (class, level, worn items; STATS_AND_ITEMS.md), rebuilt
## whenever the level or the equipment changes. Ability slots 0..3 are the hero's spells,
## slots from HERO_ABILITY_SLOTS on are the abilities of worn items, in equipment order.

enum Queue { NONE, BACK }  ## noh QUEUE_NONE / QUEUE_BACK

const BEHAVIOR_UPDATE_TIME := 0.5  ## noh BEHAVIOR_UPDATE_MS
const REPATH_DISTANCE := 0.75
const ARRIVAL_RADIUS := 0.35
const ARRIVAL_SPACING := 0.9  ## extra arrival radius per unit already standing at a shared destination
const STUCK_ARRIVAL_TIME := 0.5  ## blocked this long near the destination counts as arrived
const STUCK_ARRIVAL_DISTANCE := 4.0
const FOLLOW_DISTANCE := 1.5
const TALK_DISTANCE := 300.0 / RTSCamera.NOH_UNITS_PER_METER  ## edge to edge: close enough to talk to a neutral
const GUARD_LEASH := 1.5  ## idle units chase up to aggro_range * GUARD_LEASH from their guard spot
const GUARD_CHASE_TIME := 7.0  ## noh g_unitGuardChaseTime
const COMPANION_FOLLOW := 4.0  ## an idle companion catches up with its summoner past this
const RUN_ANIMATION_SPEED := 5.0
const RING_MESH_RADIUS := 0.67
const MAX_LEVEL := 10
const EXPERIENCE_TABLE: Array[float] = [0.0, 200.0, 500.0, 900.0, 1400.0, 2000.0, 2700.0, 3500.0, 4400.0, 5400.0]  ## DotaCraft XP_PER_LEVEL_TABLE
const LEVEL_UP_COLOR := Color(1.0, 0.85, 0.3, 0.8)
const SUMMON_FADE_TIME := 1.5
const HERO_ABILITY_SLOTS := 4  ## Q W E R
const REVIVE_TIME := 6.0  ## seconds one hero standing on a fallen hero takes to revive it
const REVIVE_RANGE := 1.6  ## how close to the body counts as standing on it
const REVIVE_HEALTH := 0.5  ## share of health a revived hero comes back with
const REVIVE_STILL_SPEED := 0.6  ## helpers must stand (nearly) still
const ITEM_ABILITY_SLOTS := 5  ## the item bar's casting slots
const PAIN_SHARE := 0.33  ## hit below this share of health: the hero cries out (HeroVoice)
const AI_CORPSE_TIME := 8.0  ## a computer-controlled hero's body lies this long, then sinks away
const CHARGE_GIVE_UP := 2000.0 / RTSCamera.NOH_UNITS_PER_METER  ## noh Order_Legionnaire_Ability2

## The stat sheet was rebuilt: level up, or equipment changed.
signal stats_changed
## An attack of this unit is a critical hit for `damage` (before the target's armor).
signal critical_hit(target: int, damage: float)

@export var definition: UnitDefinition
@export var team := 1
## Seconds a summon lives (Warcraft III timed life); 0 makes this a hero, unless it's bound.
@export var lifetime := 0.0
## A summon without timed life, a companion (Maren's Brook): it stays until it dies, and its
## summoner's ability calls it back (CallCompanion).
@export var bound := false
## The player controlling it in co-op (0: the host, or the only player).
@export var player_id := 0
## Played by the computer (HeroBrain), e.g. a creep spawner's hero: never commanded by a
## player, doesn't count toward the party's heroes, levels with the party.
@export var ai := false
## The creep spawner whose lane a computer-controlled hero walks; set before it enters the tree.
var ai_spawner: CreepSpawner
var brain: HeroBrain

## Set before the unit enters the tree.
var registry: UnitRegistry
var handle := UnitRegistry.NONE
## Set before entering the tree to reattach to a row restored from a save.
var restore_handle := UnitRegistry.NONE
var orders: Array[UnitOrder] = []
## The unit that called this summon (Brook's Maren); null for heroes.
var summoner: Unit:
	get:
		if summoner == null and _summoner_handle != UnitRegistry.NONE and registry != null:
			summoner = registry.unit_of(_summoner_handle)  # after a load, once both are back
		return summoner
## The ability that bound this companion (its resource path), so casting it again finds it.
var companion_of := ""

var level := 1
var experience := 0.0
var skill_points := 0
var mana := 0.0
var max_mana := 0.0
var lifetime_left := 0.0
var ability_levels := PackedInt32Array()
var ability_cooldowns := PackedFloat32Array()
var autocast := PackedByteArray()
var stats: StatSheet
var equipment: Array[ItemDefinition] = []  ## one entry per Equipment slot, null when empty
var item_cooldowns := PackedFloat32Array()  ## per Equipment slot
## Damage it takes is multiplied by this (an illusion of Reflection: 3).
var damage_taken := 1.0
var _ai_spawner_path := ""  ## a restored computer hero's spawner, relative to the map root
var _summoner_handle := UnitRegistry.NONE  ## a restored summon's summoner, found once it's back
var _taunt_time := 0.0  ## forced to attack (Taunt): no orders, no spells until it runs out
## Charge: {ability, target, speed, reach, time, on_arrive} while rushing at a target.
var _charge := {}

var _dead := false
var _delta := 0.0
var _attack_target := UnitRegistry.NONE
var _attack_cooldown := 0.0
var _swing_time := -1.0  ## time into the current attack swing, negative when not swinging
var _swing_target := UnitRegistry.NONE
var _swing_landed := false
var _swing_bonus := 0.0
var _swing_color := Color(0, 0, 0, 0)
var _cast: SpellCast
var _cast_slot := -1
var _cast_elapsed := 0.0
var _channeling := false
var _shield_time := 0.0
var _shield_bubble: Node3D
var _scan_timer := 0.0
var _repath_timer := 0.0
var _stuck_time := 0.0
var _chase_time := 0.0
var _guard_position := Vector3.ZERO
var _returning := false
var _anchored := false
var _desired := Vector3.ZERO  ## the last tick's wish to walk (its path, at this speed); zero: stand
var _nav_goal := Vector3.INF
var _flash_time := 0.0
var _flash_color := Color.WHITE
var _item_abilities := PackedInt32Array()  ## Equipment slots holding an item with an ability, in bar order
## Timed bonuses by id: {label, glyph, color, description, time, bonuses: {Stats.Stat: amount}}.
var _buffs: Dictionary[StringName, Dictionary] = {}
var _stealth_time := 0.0  ## time left invisible; 0 when visible
var _ambush := {}  ## buff granted when stealth is broken by attacking: {attack_speed, time}
const STEP_TIME := 0.33  ## seconds between a hero's footsteps at a run
var _step_timer := 0.0
var _cleave: Dictionary = {}  ## Wrath of the Vigil: {radius, share, until, color} (cleave_attacks)
var _split: Dictionary = {}  ## Reflection's blades: {lines, share, length, until, color} (split_attacks)
## Reflection (Fayde): stealth that lasts through attacks: {charges, cripple, ability, illusion}.
var _reflection := {}
var _revive_progress := 0.0  ## seconds of reviving done on this fallen hero
var _alive_layer := 0  ## collision layer while alive
var _ring_material := ShaderMaterial.new()
var _anim: AnimationPlayer
var _gesture_time := 0.0  ## a cast gesture plays on after the cast for this long, unless the unit moves
var _channel_clip := &"general/Interact"
var _voice: HeroVoice  ## the prefab's voice (CharacterModel.voice), or null
var _visual := Node3D.new()  ## the model, drawn on the terrain; the body stays on the gameplay plane

@onready var _agent: NavigationAgent3D = $NavigationAgent3D
@onready var _collision: CollisionShape3D = $CollisionShape3D
@onready var _ring: MeshInstance3D = $SelectionRing


func _ready() -> void:
	if restore_handle != UnitRegistry.NONE:
		handle = registry.adopt(self, restore_handle)
	else:
		handle = registry.add_summon(self) if is_summon() else registry.add_hero(self)
	if handle == UnitRegistry.NONE:
		queue_free()
		return
	Simulation.join(self, Simulation.Order.HEROES)
	_guard_position = global_position
	lifetime_left = lifetime
	var ability_count := definition.abilities.size()
	ability_levels.resize(ability_count)
	ability_cooldowns.resize(ability_count)
	autocast.resize(ability_count)
	skill_points = 1 if ability_count > 0 else 0
	for slot in ability_count:
		if definition.abilities[slot].innate:
			ability_levels[slot] = 1  # known from the start, without a skill point (Call Brook)
	equipment.resize(Equipment.count())
	item_cooldowns.resize(Equipment.count())

	var shape := CapsuleShape3D.new()
	shape.radius = definition.radius
	shape.height = definition.height
	_collision.shape = shape
	_collision.position.y = definition.height * 0.5

	_agent.radius = definition.radius
	_agent.height = definition.height
	_agent.velocity_computed.connect(_on_velocity_computed)
	_alive_layer = collision_layer
	recalculate_stats()
	mana = max_mana if definition.mana_starts_full else 0.0  # the Rogue builds combo from nothing

	var ring_scale := (definition.radius + 0.2) / RING_MESH_RADIUS
	_ring.scale = Vector3(ring_scale, 0.25, ring_scale)
	_ring_material.shader = UnitRegistry.GROUND_DECAL
	_ring.material_override = _ring_material
	_ring.visible = false

	# Gameplay is 2D: the body slides on the plane y = 0 and only the visuals follow the terrain
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_visual.name = "Visual"
	add_child(_visual)
	_update_visual()
	var model := definition.model.instantiate()
	_visual.add_child(model)
	_anim = UnitAnimations.attach(model)
	_play(&"general/Idle_A")
	if not is_summon() and model is CharacterModel and (model as CharacterModel).voice != null:
		_voice = HeroVoice.create((model as CharacterModel).voice)
		add_child(_voice)
	if ai:
		if ai_spawner == null and not _ai_spawner_path.is_empty():
			ai_spawner = registry.get_parent().get_node_or_null(_ai_spawner_path) as CreepSpawner
		brain = HeroBrain.new()
		brain.unit = self
		brain.spawner = ai_spawner
		add_child(brain)


func is_alive() -> bool:
	return not _dead


func is_summon() -> bool:
	return lifetime > 0.0 or bound


func is_channeling() -> bool:
	return _channeling


# --- Orders ------------------------------------------------------------------

func order_move(destination: Vector3, queue: Queue, group: UnitOrder.Group = null) -> void:
	_add_order(UnitOrder.to_point(UnitOrder.Type.MOVE, destination, group), queue)


func order_attack_move(destination: Vector3, queue: Queue, group: UnitOrder.Group = null) -> void:
	_add_order(UnitOrder.to_point(UnitOrder.Type.ATTACK_MOVE, destination, group), queue)


func order_patrol(destination: Vector3, queue: Queue, group: UnitOrder.Group = null) -> void:
	var order := UnitOrder.to_point(UnitOrder.Type.PATROL, destination, group)
	order.patrol_origin = global_position if queue == Queue.NONE else _last_waypoint()
	_add_order(order, queue)


## `ability_slot` makes every attack of this order use that attack modifier (Searing Arrows).
func order_attack(target: int, queue: Queue, ability_slot := -1) -> void:
	var order := UnitOrder.on_unit(UnitOrder.Type.ATTACK, target, registry)
	order.ability_slot = ability_slot
	_add_order(order, queue)


func order_follow(target: int, queue: Queue) -> void:
	_add_order(UnitOrder.on_unit(UnitOrder.Type.FOLLOW, target, registry), queue)


## Walk up to a neutral NPC and talk to it (its lines show over its head).
func order_talk(target: int, queue: Queue) -> void:
	_add_order(UnitOrder.on_unit(UnitOrder.Type.TALK, target, registry), queue)


## Walk to an item on the ground and pick it up into the party bag.
func order_pickup(item: ItemPickup, queue: Queue) -> void:
	_add_order(UnitOrder.pickup(item), queue)


func order_hold(queue: Queue) -> void:
	var order := UnitOrder.new()
	order.type = UnitOrder.Type.HOLD
	_add_order(order, queue)


## noh GAME_CMD_ABILITY / _ENTITY / _POSITION: cast the ability in `slot`.
func order_cast(slot: int, target: int, point: Vector3, queue: Queue) -> void:
	_add_order(UnitOrder.cast(slot, target, point), queue)


func order_stop() -> void:
	if _dead:
		return
	_interrupt_cast()
	orders.clear()
	_reset_engagement()
	_become_idle()


## Puts the unit somewhere else at once and leaves it idle there (Mass Teleport).
func teleport(to: Vector3) -> void:
	global_position = to
	velocity = Vector3.ZERO
	orders.clear()
	_reset_engagement()
	_become_idle()
	registry.sync_unit(handle, to, rotation.y)


## Called by the registry when this unit took damage and survived.
func on_damaged(source: int) -> void:
	# noh CBrain::Damaged: an idle unit turns on its attacker
	if orders.is_empty() and not _is_attackable(_attack_target) and _is_attackable(source):
		_attack_target = source
		_returning = false
	if registry.health_of(handle) < registry.max_health_of(handle) * PAIN_SHARE:
		say(&"pain")
	_tell_abilities(&"on_owner_damaged", [source])  # what answers being hurt (Tamsin's hawk, when she's low)
	for power in worn_powers():
		power.on_damaged(self, source)


## Calls `method(this unit, its level, args...)` on every ability it has learned (AbilityDefinition hooks).
func _tell_abilities(method: StringName, args: Array) -> void:
	for slot in mini(ability_levels.size(), definition.abilities.size()):
		var ability := definition.abilities[slot]
		if ability != null and ability_levels[slot] > 0:
			ability.callv(method, [self, ability_levels[slot]] + args)


## Called by the registry when this unit's health ran out. A hero's body stays;
## a summon fades away.
func on_killed() -> void:
	_interrupt_cast()
	_end_shield()
	_end_stealth(false)
	if not _buffs.is_empty():
		_buffs.clear()
		recalculate_stats()
	_dead = true
	orders.clear()
	_reset_engagement()
	collision_layer = 0
	_agent.avoidance_enabled = false
	velocity = Vector3.ZERO
	_ring.visible = false
	_play(&"general/Death_A", 1.0, 0.1)
	say(&"death")
	if is_summon():
		var tween := create_tween()
		tween.tween_interval(SUMMON_FADE_TIME)
		tween.tween_property(self, ^"position:y", position.y - 1.5, 1.0)
		tween.tween_callback(queue_free)
	elif ai:
		_charge = {}
		_taunt_time = 0.0
		var tween := create_tween()
		tween.tween_interval(AI_CORPSE_TIME)
		tween.tween_property(self, ^"position:y", position.y - 2.0, 1.5)
		tween.tween_callback(func() -> void:
			registry.remove_node(handle)
			queue_free())


## Says a line of the hero's voice (VoiceSet: "move", "kill"..., or "ability" with
## `ability`), if it has one and belongs to the player; HeroVoice paces them.
## It has voice lines of its own (HeroVoice).
func is_voiced() -> bool:
	return _voice != null


func say(event: StringName, ability: AbilityDefinition = null) -> void:
	if _voice == null:
		return
	if ai:
		# A computer hero only shouts its spells, kills and death, and only where the player sees it
		if (event == &"ability" or event == &"kill" or event == &"death") and registry.player_sees(handle):
			_voice.say(event, ability)
	elif team == registry.player_team:
		_voice.say(event, ability)


## Briefly blinks the selection ring, used to confirm a unit was targeted by an order.
func flash(color: Color) -> void:
	_flash_time = 0.6
	_flash_color = color


func set_highlight(selected: bool, hovered: bool, color: Color) -> void:
	if _dead:
		_ring.visible = false
		return
	var blink := _flash_time > 0.0 and fmod(_flash_time, 0.2) > 0.1
	_ring.visible = selected or hovered or blink
	if blink:
		_ring_material.set_shader_parameter(&"color", _flash_color)
	else:
		_ring_material.set_shader_parameter(&"color", Color(color, 1.0 if selected else 0.45))


# --- Hero progression and abilities ---------------------------------------------

func add_experience(amount: float) -> void:
	if _dead or is_summon():
		return
	experience += amount
	var gained := false
	while level < MAX_LEVEL and experience >= EXPERIENCE_TABLE[level]:
		level += 1
		skill_points += 1
		gained = true
	if gained:
		recalculate_stats()  # the class's stats grow with every level
		SpellEffects.pillar(registry, global_position, LEVEL_UP_COLOR, 0.8, 4.0, 0.8)
		say(&"level_up")


## Progress from this level to the next, 0..1.
func experience_progress() -> float:
	if level >= MAX_LEVEL:
		return 1.0
	var floor_xp := EXPERIENCE_TABLE[level - 1]
	return clampf((experience - floor_xp) / (EXPERIENCE_TABLE[level] - floor_xp), 0.0, 1.0)


func attack_damage() -> float:
	return stats.value(Stats.Stat.ATTACK_DAMAGE)


## Worn weapon's attack type, else the unit's own (null: plain damage).
func attack_type() -> AttackType:
	var weapon := equipment[Equipment.WEAPON]
	return weapon.attack_type if weapon != null and weapon.attack_type != null else definition.attack_type


## Rebuilds the stat sheet from class, level and equipment and applies it everywhere.
func recalculate_stats() -> void:
	var extras := []
	for id in _buffs:
		var buff: Dictionary = _buffs[id]
		for stat: int in buff.bonuses:
			extras.append([buff.label, stat, buff.bonuses[stat]])
	stats = StatSheet.build(definition, level, equipment, extras)
	var share := mana / max_mana if max_mana > 0.0 else 1.0
	max_mana = stats.value(Stats.Stat.MAX_MANA)
	mana = share * max_mana
	registry.set_max_health(handle, stats.value(Stats.Stat.MAX_HEALTH))
	var evasion := stats.effective(Stats.Stat.EVASION)
	for id in _buffs:
		evasion = maxf(evasion, _buffs[id].get("evasion", 0.0))  # outside the rating: Shadow Stance's 100%
	registry.set_combat_stats(handle, stats.value(Stats.Stat.ARMOR), evasion,
			stats.effective(Stats.Stat.PARRY), stats.value(Stats.Stat.SPELL_DAMAGE), attack_type())
	_agent.max_speed = move_speed()
	stats_changed.emit()


func move_speed() -> float:
	return stats.value(Stats.Stat.MOVE_SPEED) * (1.0 - registry.slow_of(handle))


## Attack speed makes the whole attack faster: cooldown and swing (Warcraft III).
func attack_speed_factor() -> float:
	return (1.0 + maxf(stats.value(Stats.Stat.ATTACK_SPEED), -50.0) / 100.0) * (1.0 - registry.attack_slow_of(handle))


## Cast speed shortens the wind-up before a spell goes off (not channels or cooldowns).
func cast_speed_factor() -> float:
	return 1.0 + maxf(stats.value(Stats.Stat.CAST_SPEED), -50.0) / 100.0


## What the ability in `slot` costs this unit, after mana cost reduction.
func mana_cost(slot: int) -> float:
	var ability := ability_at(slot)
	if ability == null:
		return 0.0
	return ability.mana_cost_at(maxi(ability_level(slot), 1)) * (1.0 - stats.effective(Stats.Stat.MANA_COST_REDUCTION) / 100.0)


# --- Combo, buffs and stealth (the Rogue) ---------------------------------------

## Adds combo mana (hits, parries), grown by Combo power.
func gain_combo(amount: float) -> void:
	if amount > 0.0 and not _dead:
		mana = minf(max_mana, mana + amount * (1.0 + stats.value(Stats.Stat.COMBO_POWER) / 100.0))


## Called by the registry when this unit parried an attack from `source`.
func on_parried(_source: int) -> void:
	gain_combo(definition.mana_per_parry)
	flash(Color(1.0, 0.9, 0.5))


## Whether this unit stands behind `target` (outside the front 110 degrees of its facing).
func is_behind(target: int) -> bool:
	if registry.life_of(target) == UnitRegistry.Life.FREE:
		return false
	var yaw := registry.yaw_of(target)
	var facing := Vector2(sin(yaw), cos(yaw))  # KayKit models face +Z
	var offset := global_position - registry.position_of(target)
	var to_attacker := Vector2(offset.x, offset.z)
	return to_attacker.length_squared() > 0.0001 and facing.dot(to_attacker.normalized()) < -0.35


## A timed bonus (Riposte, Ambush); adding one that runs already restarts it.
## A timed buff: `bonuses` add to stats ({Stats.Stat: amount}); `evasion` is a flat chance
## to dodge attacks outside the evasion rating (Shadow Stance: 100).
func add_buff(id: StringName, label: String, glyph: String, color: Color, description: String, seconds: float,
		bonuses: Dictionary, evasion := 0.0) -> void:
	_buffs[id] = {"label": label, "glyph": glyph, "color": color, "description": description, "time": seconds,
			"bonuses": bonuses, "evasion": evasion}
	recalculate_stats()


## Ends the buff `id` now, if it has it (the last night's meal, at the next rest).
func remove_buff(id: StringName) -> void:
	if _buffs.erase(id):
		recalculate_stats()


## Busy with something a computer player shouldn't interrupt: a cast, a charge, a taunt.
func is_busy() -> bool:
	return _cast != null or not _charge.is_empty() or _taunt_time > 0.0


## Taunted by `attacker` (Legionnaire's Taunt): attacks it for `seconds` and can't be given
## orders or cast meanwhile (noh: a forced attack order, silenced).
func taunt(attacker: int, seconds: float) -> void:
	if _dead:
		return
	_interrupt_cast()
	_charge = {}
	orders.clear()
	_reset_engagement()
	orders.append(UnitOrder.on_unit(UnitOrder.Type.ATTACK, attacker, registry))
	_taunt_time = seconds


## Rushes at `target` at `speed` m/s (Legionnaire's Charge), sliding along the navigation
## mesh; within `reach` of it, calls `on_arrive(target)`. Gives up after `max_time`, or if the
## target dies, hides or gets CHARGE_GIVE_UP away. Plays the model's "<ability>_run" clip.
func charge(ability: AbilityDefinition, target: int, speed: float, reach: float, max_time: float, on_arrive: Callable) -> void:
	_charge = {"ability": ability, "target": target, "speed": speed, "reach": reach, "time": max_time, "on_arrive": on_arrive}
	_gesture_time = 0.0
	_play(UnitAnimations.ability_clip(_anim, ability, "_run", &"move/Running_A"), 1.5, 0.1)


func _update_charge(delta: float) -> void:
	var target: int = _charge.target
	_charge.time -= delta
	if _charge.time <= 0.0 or not _is_attackable(target) or registry.edge_distance(handle, target) > CHARGE_GIVE_UP:
		_charge = {}
		return
	if registry.edge_distance(handle, target) <= _charge.reach:
		var arrive: Callable = _charge.on_arrive
		_charge = {}
		velocity = Vector3.ZERO
		if arrive.is_valid():
			arrive.call(target)
		return
	var to := registry.position_of(target) - global_position
	to.y = 0.0
	var step := to.normalized() * minf(_charge.speed * delta, to.length())
	var wanted := global_position + step
	var moved := WalkGrid.current.step(global_position, wanted) if WalkGrid.current != null else Vector3.INF
	if moved == Vector3.INF:
		moved = NavigationServer3D.map_get_closest_point(_agent.get_navigation_map(), wanted)
	global_position = Vector3(moved.x, global_position.y, moved.z)
	rotation.y = atan2(to.x, to.z)
	velocity = to.normalized() * _charge.speed
	_agent.velocity = Vector3.ZERO
	registry.sync_unit(handle, global_position, rotation.y)


## Called by the registry when an attack is about to hit this unit: passives that answer
## attacks (Whirling Blade) get their chance.
func on_attacked(source: int) -> void:
	if _dead:
		return
	for slot in definition.abilities.size():
		var ability := definition.abilities[slot]
		if ability_level(slot) > 0 and ability_cooldowns[slot] <= 0.0 and ability.has_method(&"on_owner_attacked"):
			ability.call(&"on_owner_attacked", self, slot, source)


## Plays the model's own clip for `ability` (+ `suffix`) as a gesture, if it has one and isn't
## mid-swing or casting: a passive going off, a charge landing.
func play_ability_clip(ability: AbilityDefinition, suffix := "") -> void:
	var clip := UnitAnimations.ability_clip(_anim, ability, suffix, &"")
	if clip != &"" and _swing_time < 0.0 and _cast == null:
		_play_gesture(clip, 1.0)


## noh disjoint: projectiles flying at this unit miss.
func disjoint() -> void:
	Projectile.disjoint(get_tree(), handle)


## Reflection (Fayde): invisible for `seconds` with `charges` attacks. Attacks don't reveal;
## each landed one applies Shadow Cripple (`cripple`: {slow, dps, time}) and the first
## also ends `illusion`. Out of charges, or casting a spell, ends it.
func reflect(ability: AbilityDefinition, seconds: float, charges: int, cripple: Dictionary, illusion: Unit) -> void:
	_stealth_time = seconds
	_ambush = {}
	_reflection = {"charges": charges, "cripple": cripple, "ability": ability, "illusion": illusion}
	registry.set_stealth(handle, true)
	_set_ghost(true)


## The running buffs for the item bar, stealth included.
func buffs() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	if _taunt_time > 0.0:
		list.append({"label": "Taunted", "glyph": "Ta", "color": Color(0.8, 0.25, 0.2), "time": _taunt_time,
				"description": "Forced to attack the taunter; no orders or spells until it ends."})
	if _stealth_time > 0.0 and not _reflection.is_empty():
		var speed: String = _buffs[&"reflection"].description + " " if _buffs.has(&"reflection") else ""
		list.append({"label": "Reflection", "glyph": "Re", "color": Color(0.35, 0.2, 0.3), "time": _stealth_time,
				"count": _reflection.charges,  # shown on the icon: attacking doesn't reveal until they run out
				"description": "Invisible to enemies. %s%d attacks left that cripple; casting a spell ends it." % [speed, _reflection.charges]})
	elif _stealth_time > 0.0:
		list.append({"label": "Vanished", "glyph": "Va", "color": Color(0.35, 0.25, 0.5), "time": _stealth_time,
				"description": "Invisible to enemies. Attacking out of it is an ambush; casting a spell ends it."})
	for id in _buffs:
		if id == &"reflection" and not _reflection.is_empty():
			continue  # its speed is part of the Reflection icon above
		list.append(_buffs[id])
	return list


func _update_buffs(delta: float) -> void:
	if _stealth_time > 0.0:
		_stealth_time -= delta
		if _stealth_time <= 0.0:
			_end_stealth(false)
	if _buffs.is_empty():
		return
	var expired := false
	for id in _buffs.keys():
		_buffs[id].time -= delta
		if _buffs[id].time <= 0.0:
			_buffs.erase(id)
			expired = true
	if expired:
		recalculate_stats()


## Vanish: invisible to other teams for `seconds`. Attacking out of it grants `ambush_speed`
## percent attack speed for `ambush_seconds`; casting another spell just ends it.
func vanish(seconds: float, ambush_speed: float, ambush_seconds: float) -> void:
	_stealth_time = seconds
	_ambush = {"attack_speed": ambush_speed, "time": ambush_seconds}
	registry.set_stealth(handle, true)
	_set_ghost(true)


func is_stealthed() -> bool:
	return _stealth_time > 0.0


func _end_stealth(ambush: bool) -> void:
	if _stealth_time <= 0.0:
		return
	_stealth_time = 0.0
	registry.set_stealth(handle, false)
	_set_ghost(false)
	if not _reflection.is_empty():
		_reflection = {}
		if _buffs.erase(&"reflection"):
			recalculate_stats()
	if ambush and not _ambush.is_empty():
		add_buff(&"ambush", "Ambush", "Am", Color(0.85, 0.35, 0.45),
				"Struck from the shadows: +%d%% attack speed." % roundi(_ambush.attack_speed), _ambush.time,
				{Stats.Stat.ATTACK_SPEED: _ambush.attack_speed})
	_ambush = {}


## Own units see a stealthed hero as a see-through shape.
func _set_ghost(ghost: bool) -> void:
	for node in _visual.find_children("*", "GeometryInstance3D", true, false):
		(node as GeometryInstance3D).transparency = 0.6 if ghost else 0.0


## Moves straight to `at` without touching orders (Swift Slashes' strikes).
func blink_to(at: Vector3) -> void:
	global_position = Vector3(at.x, global_position.y, at.z)
	velocity = Vector3.ZERO
	registry.sync_unit(handle, global_position, rotation.y)


# --- Reviving fallen heroes -------------------------------------------------------

## A fallen hero comes back when living heroes of its party stand still on its body for
## REVIVE_TIME seconds; every extra helper speeds it up (two helpers: half the time).
## Stepping away lets the progress run back down.
func _update_revive(delta: float) -> void:
	if is_summon() or ai or handle == UnitRegistry.NONE:
		return
	var helpers := 0
	for other in registry.unit_nodes():
		if other == self or not other.is_alive() or other.team != team or other.is_summon() or other.ai:
			continue
		var offset := other.global_position - global_position
		if Vector2(offset.x, offset.z).length() <= REVIVE_RANGE \
				and Vector2(other.velocity.x, other.velocity.z).length() < REVIVE_STILL_SPEED:
			helpers += 1
	if helpers == 0:
		_revive_progress = maxf(_revive_progress - delta, 0.0)
		return
	_revive_progress += delta * helpers
	if _revive_progress >= REVIVE_TIME:
		revive(REVIVE_HEALTH)


## 0..1 while someone revives this fallen hero, for the overlay.
func revive_progress() -> float:
	return clampf(_revive_progress / REVIVE_TIME, 0.0, 1.0)


## Back on its feet with `health_share` of its health.
func revive(health_share: float) -> void:
	if not _dead:
		return
	_dead = false
	_revive_progress = 0.0
	registry.revive(handle, health_share)
	collision_layer = _alive_layer
	_agent.avoidance_enabled = true
	orders.clear()
	_reset_engagement()
	_guard_position = global_position
	_play(&"general/Idle_A", 1.0, 0.2)
	SpellEffects.pillar(registry, global_position, LEVEL_UP_COLOR, 0.8, 4.0, 0.8)
	say(&"revive")


# --- Saving --------------------------------------------------------------------

## Everything about this unit a save needs, as plain data (SaveCodec). Orders and casts in
## progress aren't kept: a loaded unit stands idle.
func save_state() -> Dictionary:
	var max_health := registry.max_health_of(handle)
	return {
		"definition": SaveCodec.encode_resource(definition),
		"team": team,
		"player": player_id,
		"lifetime": lifetime,
		"lifetime_left": lifetime_left,
		"bound": bound,
		"summoner": summoner.handle if is_instance_valid(summoner) else UnitRegistry.NONE,
		"companion_of": companion_of,
		"handle": handle,
		"position": global_position,
		"yaw": rotation.y,
		"guard_position": _guard_position,
		"health_share": registry.health_of(handle) / max_health if max_health > 0.0 else 1.0,
		"dead": _dead,
		"level": level,
		"experience": experience,
		"skill_points": skill_points,
		"mana": mana,
		"ability_levels": ability_levels.duplicate(),
		"ability_cooldowns": ability_cooldowns.duplicate(),
		"autocast": autocast.duplicate(),
		"equipment": SaveCodec.encode_resources(equipment),
		"item_cooldowns": item_cooldowns.duplicate(),
		"shield_time": _shield_time,
		"buffs": _buffs.duplicate(true),
		"stealth_time": _stealth_time,
		"ambush": _ambush.duplicate(),
		"reflection": {} if _reflection.is_empty() else {"charges": _reflection.charges,
				"cripple": _reflection.cripple.duplicate(), "ability": SaveCodec.encode_resource(_reflection.ability)},
		"damage_taken": damage_taken,
		"ai": ai,
		"ai_spawner": str(registry.get_parent().get_path_to(ai_spawner)) if ai_spawner != null else "",
	}


## A unit made from save_state() data. `restore_handle` puts it back on its saved row;
## without one (a party arriving on a new map) it gets a fresh row at `at`.
static func from_state(data: Dictionary, unit_registry: UnitRegistry, at := Vector3.INF) -> Unit:
	var unit: Unit = load("res://scenes/unit.tscn").instantiate()
	unit.definition = SaveCodec.decode_resource(data.definition) as UnitDefinition
	unit.team = data.team
	unit.player_id = data.player
	unit.lifetime = data.lifetime
	unit.bound = data.get("bound", false)
	unit._summoner_handle = data.get("summoner", UnitRegistry.NONE)
	unit.companion_of = data.get("companion_of", "")
	unit.registry = unit_registry
	unit.position = data.position if at == Vector3.INF else at
	unit.rotation.y = data.yaw
	unit.ai = data.get("ai", false)
	unit._ai_spawner_path = data.get("ai_spawner", "")
	if at == Vector3.INF:
		unit.restore_handle = data.handle
	return unit


## Applies save_state() data once the unit is in the tree. `fresh_row`: the registry row is
## new (a party arriving on a map), so the saved share of health is applied to it.
func restore_state(data: Dictionary, fresh_row := false) -> void:
	level = data.level
	experience = data.experience
	skill_points = data.skill_points
	lifetime_left = data.lifetime_left
	if not fresh_row:
		_guard_position = data.guard_position
	ability_levels = PackedInt32Array(data.ability_levels)
	ability_cooldowns = PackedFloat32Array(data.ability_cooldowns)
	autocast = PackedByteArray(data.autocast)
	# A class that gained or lost an ability since the save
	ability_levels.resize(definition.abilities.size())
	ability_cooldowns.resize(definition.abilities.size())
	autocast.resize(definition.abilities.size())
	SaveCodec.decode_resources_into(data.equipment, equipment)
	equipment.resize(Equipment.count())
	item_cooldowns = PackedFloat32Array(data.item_cooldowns)
	item_cooldowns.resize(Equipment.count())
	_on_equipment_changed()  # rebuilds the stats for the level and the items
	mana = minf(data.mana, max_mana)
	if fresh_row and not data.dead:
		registry.set_health(handle, data.health_share * registry.max_health_of(handle))
	if data.shield_time > 0.0:
		shield(data.shield_time, Color(1.0, 0.85, 0.4, 0.35))
	_buffs.assign(data.get("buffs", {}))
	if data.get("stealth_time", 0.0) > 0.0:
		vanish(data.stealth_time, 0.0, 0.0)
		_ambush = data.ambush
		var reflection: Dictionary = data.get("reflection", {})
		if not reflection.is_empty():
			_reflection = {"charges": reflection.charges, "cripple": reflection.cripple,
					"ability": SaveCodec.decode_resource(reflection.ability), "illusion": null}
	damage_taken = data.get("damage_taken", 1.0)
	recalculate_stats()
	if data.dead and fresh_row:
		registry.kill(handle)  # a fresh row is alive; this lays the hero down
	elif data.dead:
		_lie_dead()


## A fallen hero loaded from a save: down where it fell, without dying again.
func _lie_dead() -> void:
	_dead = true
	collision_layer = 0
	_agent.avoidance_enabled = false
	_ring.visible = false
	_play(&"general/Death_A", 1.0, 0.0)
	_anim.seek(_anim.current_animation_length, true)


# --- Equipment -----------------------------------------------------------------

## Wears `item` in the Equipment slot `index` (null takes it off) and returns what was there.
## The party inventory checks that it fits.
func set_equipped(index: int, item: ItemDefinition) -> ItemDefinition:
	var previous := equipment[index]
	equipment[index] = item
	_on_equipment_changed()
	return previous


func _on_equipment_changed() -> void:
	# The item bar shifts: drop item casts that point at it
	if _cast_slot >= HERO_ABILITY_SLOTS:
		_finish_cast(true)
	for i in range(orders.size() - 1, -1, -1):
		var order := orders[i]
		if order.type == UnitOrder.Type.CAST and order.ability_slot >= HERO_ABILITY_SLOTS:
			orders.remove_at(i)
	_item_abilities.clear()
	for index in equipment.size():
		var item := equipment[index]
		if item != null and item.ability != null and _item_abilities.size() < ITEM_ABILITY_SLOTS:
			_item_abilities.append(index)
	recalculate_stats()


# --- Ability slots: hero spells, then item abilities ---------------------------

## The ability in `slot`, or null.
func ability_at(slot: int) -> AbilityDefinition:
	if slot >= 0 and slot < HERO_ABILITY_SLOTS:
		return definition.abilities[slot] if slot < definition.abilities.size() else null
	var index := item_ability_equipment(slot)
	return equipment[index].ability if index >= 0 else null


## The Equipment slot behind an item ability slot, or -1.
func item_ability_equipment(slot: int) -> int:
	var i := slot - HERO_ABILITY_SLOTS
	return _item_abilities[i] if i >= 0 and i < _item_abilities.size() else -1


## Learned level; item abilities are always level 1.
func ability_level(slot: int) -> int:
	if slot >= 0 and slot < ability_levels.size():
		return ability_levels[slot]
	return 1 if item_ability_equipment(slot) >= 0 else 0


func ability_cooldown(slot: int) -> float:
	if slot >= 0 and slot < ability_cooldowns.size():
		return ability_cooldowns[slot]
	var index := item_ability_equipment(slot)
	return item_cooldowns[index] if index >= 0 else 0.0


func is_autocast(slot: int) -> bool:
	return slot >= 0 and slot < autocast.size() and autocast[slot] != 0


func _start_cooldown(slot: int, seconds: float) -> void:
	if slot >= 0 and slot < ability_cooldowns.size():
		ability_cooldowns[slot] = seconds
	elif item_ability_equipment(slot) >= 0:
		item_cooldowns[item_ability_equipment(slot)] = seconds


func can_learn(slot: int) -> bool:
	if skill_points <= 0 or slot < 0 or slot >= definition.abilities.size():
		return false
	var ability := definition.abilities[slot]
	var next := ability_levels[slot] + 1
	return next <= ability.max_level and level >= ability.required_hero_level(next)


func learn(slot: int) -> bool:
	if not can_learn(slot):
		return false
	ability_levels[slot] += 1
	skill_points -= 1
	return true


## Why the ability in `slot` can't be used right now, or "" (noh's ErrorMessage texts).
func ability_error(slot: int) -> String:
	var ability := ability_at(slot)
	if _dead or ability == null:
		return "No ability"
	if _taunt_time > 0.0:
		return "Taunted"
	if ability_level(slot) < 1:
		return "Ability not learned yet"
	if ability.is_passive():
		return "Passive ability"
	if ability_cooldown(slot) > 0.0:
		return "%s is not ready yet" % ability.display_name
	if mana < mana_cost(slot):
		return "Not enough mana"
	return ""


func cooldown_fraction(slot: int) -> float:
	var ability := ability_at(slot)
	if ability == null:
		return 0.0
	var total := ability.cooldown_at(maxi(ability_level(slot), 1))
	return clampf(ability_cooldown(slot) / total, 0.0, 1.0) if total > 0.0 else 0.0


## Searing Arrows style abilities: right-click on the button toggles autocast.
func toggle_autocast(slot: int) -> void:
	if slot >= 0 and slot < autocast.size() and ability_levels[slot] > 0 \
			and definition.abilities[slot].action == AbilityDefinition.Action.ATTACK:
		autocast[slot] = 0 if autocast[slot] else 1


## The learned auras this unit radiates, for the registry's aura pass.
func active_auras() -> Array[Dictionary]:
	var auras: Array[Dictionary] = []
	if _dead:
		return auras
	for slot in HERO_ABILITY_SLOTS + _item_abilities.size():
		var ability := ability_at(slot)
		if ability is AuraAbility and ability_level(slot) > 0:
			auras.append({ability = ability, level = ability_level(slot)})
	return auras


## Divine Shield: no damage for `duration` seconds.
func shield(duration: float, color: Color) -> void:
	_shield_time = maxf(_shield_time, duration)
	registry.set_invulnerable(handle, true)
	if _shield_bubble == null:
		_shield_bubble = SpellEffects.bubble(_visual, definition.height * 0.6, color, definition.height * 0.5)


func _end_shield() -> void:
	_shield_time = 0.0
	if handle != UnitRegistry.NONE:
		registry.set_invulnerable(handle, false)
	if _shield_bubble != null:
		SpellEffects.stop(_shield_bubble)
		_shield_bubble = null


func _add_order(order: UnitOrder, queue: Queue) -> void:
	if _dead or _taunt_time > 0.0:
		return  # a taunted unit keeps attacking its taunter
	if queue == Queue.NONE:
		_interrupt_cast()
		# Re-ordering an attack on the current swing target keeps the swing going
		var same_swing := order.type == UnitOrder.Type.ATTACK and order.target == _swing_target and _swing_time >= 0.0
		orders.clear()
		if not same_swing:
			_reset_engagement()
		_scan_timer = 0.0
	orders.append(order)


func _last_waypoint() -> Vector3:
	for i in range(orders.size() - 1, -1, -1):
		if orders[i].type != UnitOrder.Type.HOLD:
			return orders[i].get_world_position(registry)
	return global_position


func _pop_order() -> void:
	if not orders.is_empty():
		orders.pop_front()
	_attack_target = UnitRegistry.NONE
	_nav_goal = Vector3.INF
	_stuck_time = 0.0
	if orders.is_empty():
		_become_idle()


func _become_idle() -> void:
	_guard_position = global_position
	_returning = false
	_chase_time = 0.0


func _reset_engagement() -> void:
	_desired = Vector3.ZERO
	_attack_target = UnitRegistry.NONE
	_swing_time = -1.0
	_swing_target = UnitRegistry.NONE
	_returning = false
	_nav_goal = Vector3.INF
	_stuck_time = 0.0
	_chase_time = 0.0


# --- Per-frame behavior --------------------------------------------------------

func _process(_frame_time: float) -> void:
	_update_visual()
	if team != registry.player_team and handle != UnitRegistry.NONE:
		_visual.visible = registry.player_sees(handle)  # other teams' heroes hide in the fog like creeps


## Puts the model on the terrain under the body.
func _update_visual() -> void:
	_visual.position.y = Terrain.ground(global_position.x, global_position.z)


## The rules half of a step, on the game's clock (Simulation): timers, buffs, regeneration,
## orders, swings and casts. It works out whether and where the unit walks (the agent's target,
## `_desired`); the physics step below steers the body along the path.
func _simulate(delta: float) -> void:
	if _dead:
		_update_revive(delta)
		return
	if not registry.nav_ready:
		return
	_delta = delta

	_attack_cooldown = maxf(_attack_cooldown - delta, 0.0)
	_scan_timer -= delta
	_repath_timer -= delta
	_flash_time = maxf(_flash_time - delta, 0.0)
	for slot in ability_cooldowns.size():
		ability_cooldowns[slot] = maxf(ability_cooldowns[slot] - delta, 0.0)
	for index in item_cooldowns.size():
		item_cooldowns[index] = maxf(item_cooldowns[index] - delta, 0.0)
	var mana_regen := stats.value(Stats.Stat.MANA_REGEN) + registry.mana_regen_bonus_of(handle)
	mana = clampf(mana + mana_regen * delta, 0.0, max_mana)  # the Rogue's combo drains to empty
	_update_buffs(delta)
	registry.heal(handle, stats.value(Stats.Stat.HEALTH_REGEN) * delta)
	if _shield_time > 0.0:
		_shield_time -= delta
		if _shield_time <= 0.0:
			_end_shield()
	if lifetime > 0.0:
		lifetime_left -= delta
		if lifetime_left <= 0.0:
			registry.kill(handle)
			return
	_anchored = false
	_desired = Vector3.ZERO
	_taunt_time = maxf(_taunt_time - delta, 0.0)
	if registry.is_stunned(handle):
		_interrupt_cast()
		_charge = {}
		_swing_time = -1.0
		return
	if not _charge.is_empty():
		return  # the charge moves it, in the physics step

	if _cast != null:
		_update_cast(delta)
		_anchored = true
	elif _swing_time >= 0.0:
		_update_swing(delta)
		_anchored = true
	else:
		_desired = _think()
	_update_stuck(delta, _desired)


## The physics half, every physics step: moves the body (a charge, or along its path as the last
## tick asked, through avoidance: _on_velocity_computed), turns it and picks its animation.
func _physics_process(delta: float) -> void:
	if _dead or not registry.nav_ready:
		return
	if registry.is_stunned(handle):
		_agent.velocity = Vector3.ZERO
		_update_animation(delta)
		return
	if not _charge.is_empty():
		_update_charge(delta)
		return
	# Moving creeps (0.5) step around player units; standing fighters (1.0) don't move for anyone
	_agent.avoidance_priority = 1.0 if _anchored else 0.75
	_agent.velocity = _steer()
	_update_facing(delta)
	_update_animation(delta)


## Toward the agent's next path point at the speed the last tick asked for. Steering every physics
## step keeps the body on its path however many steps run between two ticks (a slow frame, or the
## tests' speed-up, runs them in bursts).
func _steer() -> Vector3:
	if _desired == Vector3.ZERO or _agent.is_navigation_finished():
		return Vector3.ZERO
	var to_next := _agent.get_next_path_position() - global_position
	to_next.y = 0.0
	if to_next.length_squared() < 0.0001:
		return Vector3.ZERO
	return to_next.normalized() * _desired.length()


func _think() -> Vector3:
	if orders.is_empty():
		return _think_idle()

	var order := orders[0]
	match order.type:
		UnitOrder.Type.MOVE:
			if _arrived(order):
				_pop_order()
				return Vector3.ZERO
			return _seek(order.position)

		UnitOrder.Type.ATTACK:
			if order.target == handle or not registry.is_alive(order.target):
				_pop_order()
				return Vector3.ZERO
			if not registry.can_see(team, order.target):
				# noh CBAttack: out of sight, head for where it was last seen and give up there
				if _arrived(order):
					_pop_order()
					return Vector3.ZERO
				return _seek(order.position)
			order.position = registry.position_of(order.target)
			if not order.aggro_triggered and registry.edge_distance(handle, order.target) <= UnitRegistry.ATTACK_AGGRO_TRIGGER_RANGE:
				order.aggro_triggered = true
				registry.attack_order_aggro(handle, order.target)
			return _engage(order.target, true)

		UnitOrder.Type.ATTACK_MOVE, UnitOrder.Type.PATROL:
			_scan_for_target(definition.aggro_range)
			if _is_attackable(_attack_target):
				return _engage(_attack_target, true)
			if _arrived(order):
				if order.type == UnitOrder.Type.PATROL:
					order.turn_around(handle)
					_nav_goal = Vector3.INF
				else:
					_pop_order()
				return Vector3.ZERO
			return _seek(order.position)

		UnitOrder.Type.FOLLOW:
			if not _is_attackable(order.target):
				_pop_order()
				return Vector3.ZERO
			if registry.edge_distance(handle, order.target) <= FOLLOW_DISTANCE:
				return Vector3.ZERO
			return _seek(order.get_world_position(registry))

		UnitOrder.Type.TALK:
			if not registry.is_neutral(order.target):
				_pop_order()
				return Vector3.ZERO
			if registry.edge_distance(handle, order.target) <= TALK_DISTANCE:
				registry.talk(order.target, handle)
				_pop_order()
				return Vector3.ZERO
			return _seek(order.get_world_position(registry))

		UnitOrder.Type.PICKUP:
			var item := order.item
			if not is_instance_valid(item) or item.is_queued_for_deletion():
				_pop_order()  # somebody else got it
				return Vector3.ZERO
			item.mark_targeted()
			if _flat_distance(global_position, item.ground_spot()) <= ItemPickup.PICKUP_RANGE:
				var error := item.pick_up(self)
				if not error.is_empty():
					var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
					if party != null:
						party.commander.show_error(error)
				_pop_order()
				return Vector3.ZERO
			return _seek(item.ground_spot())

		UnitOrder.Type.HOLD:
			_anchored = true
			if _is_attackable(_attack_target) and not _in_attack_range(_attack_target):
				_attack_target = UnitRegistry.NONE
			_scan_for_target(attack_range())
			if _is_attackable(_attack_target):
				_engage(_attack_target, false)
			return Vector3.ZERO

		UnitOrder.Type.CAST:
			return _think_cast(order)

	return Vector3.ZERO


## noh CBGuard: fight what comes near, but give up after GUARD_CHASE_TIME or past the
## leash and walk back to the guard spot.
func _think_idle() -> Vector3:
	var companion := bound and is_instance_valid(summoner) and summoner.is_alive()
	if companion:
		_guard_position = summoner.global_position  # a companion guards its summoner, wherever she goes
	if _returning:
		if _flat_distance(global_position, _guard_position) <= ARRIVAL_RADIUS or _agent.is_navigation_finished():
			_returning = false
			return Vector3.ZERO
		return _seek(_guard_position)

	var too_far := _flat_distance(global_position, _guard_position) > definition.aggro_range * GUARD_LEASH
	if _is_attackable(_attack_target) and (too_far or _chase_time > GUARD_CHASE_TIME):
		_attack_target = UnitRegistry.NONE
		_returning = true
		_chase_time = 0.0
		return _seek(_guard_position)

	_scan_for_target(definition.aggro_range)
	if not _is_attackable(_attack_target):
		_chase_time = 0.0
		if companion and _flat_distance(global_position, _guard_position) > COMPANION_FOLLOW:
			return _seek(_guard_position)  # catching up with her
		return Vector3.ZERO
	var desired := _engage(_attack_target, true)
	_chase_time = _chase_time + _delta if desired != Vector3.ZERO else 0.0
	return desired


## Walks into cast range, then starts the cast (noh: the ability behavior of CBrain).
func _think_cast(order: UnitOrder) -> Vector3:
	var slot := order.ability_slot
	var ability := ability_at(slot)
	if not ability_error(slot).is_empty():
		_pop_order()
		return Vector3.ZERO
	var targeted := order.target != UnitRegistry.NONE
	if targeted and (not registry.is_alive(order.target) or not registry.can_see(team, order.target)):
		_pop_order()  # noh CASCasting: dead, or gone into the fog
		return Vector3.ZERO
	var aim := order.get_world_position(registry)
	if ability.cast_range > 0.0 and not (targeted and order.target == handle):
		var reach := registry.edge_distance(handle, order.target) if targeted else _flat_distance(global_position, aim)
		if reach > ability.cast_range:
			return _seek(aim)

	_cast = SpellCast.new()
	_cast.ability = ability
	_cast.level = ability_level(slot)
	_cast.caster = self
	_cast.registry = registry
	_cast.target = order.target
	_cast.point = aim
	_cast_slot = slot
	_cast_elapsed = 0.0
	_channeling = false
	# The model's own clip for this spell plays out at its pace; the shared one quickly
	var gesture := UnitAnimations.ability_clip(_anim, ability, "", &"general/Use_Item")
	_play_gesture(gesture, 2.0 if gesture == &"general/Use_Item" else cast_speed_factor())
	say(&"ability", ability)
	return Vector3.ZERO


func _update_cast(delta: float) -> void:
	var spell := _cast
	if not _channeling:
		_cast_elapsed += delta * cast_speed_factor()
		if _cast_elapsed < spell.ability.cast_point:
			return
		# The cast point: pay and fire
		if not ability_error(_cast_slot).is_empty() or (spell.target != UnitRegistry.NONE \
				and spell.ability.action == AbilityDefinition.Action.TARGET_UNIT \
				and not (registry.is_alive(spell.target) and registry.can_see(team, spell.target))):
			_finish_cast(false)
			return
		spell.mana_spent = mana_cost(_cast_slot)
		mana -= spell.mana_spent
		_start_cooldown(_cast_slot, spell.ability.cooldown_at(spell.level))
		if spell.ability.breaks_stealth:
			_end_stealth(false)
		spell.ability.cast(spell)
		_tell_abilities(&"on_owner_cast", [spell.ability])  # passives that answer every spell (Seeking Arrows)
		for power in worn_powers():
			power.on_cast(self, spell.ability, spell)
		if spell.ability.element != &"none" and spell.ability.channel_time_at(spell.level) <= 0.0:  # channels sound as they go
			var at := registry.position_of(spell.target) if registry.is_alive(spell.target) else spell.point
			Sounds.play_at(spell.ability.element, at)  # the spell's impact, by element
		if spell.ability.channel_time_at(spell.level) > 0.0:
			_channeling = true
			_gesture_time = 0.0
			_channel_clip = UnitAnimations.ability_clip(_anim, spell.ability, "_channel", &"general/Interact")
			_play(_channel_clip, 1.0, 0.15)
		else:
			_finish_cast(false)
		return

	spell.elapsed += delta
	spell.ability.channel(spell, delta)
	if not _anim.is_playing():
		_play(_channel_clip, 1.0, 0.0)
		_anim.seek(0.0, true)
	if spell.elapsed >= spell.ability.channel_time_at(spell.level):
		_finish_cast(false)


func _finish_cast(interrupted: bool) -> void:
	var spell := _cast
	if spell == null:
		return
	_cast = null
	if _channeling:
		_channeling = false
		spell.ability.end_channel(spell, interrupted)
	spell.free_effects()
	if not interrupted and not orders.is_empty() and orders[0].type == UnitOrder.Type.CAST:
		_pop_order()


func _interrupt_cast() -> void:
	_finish_cast(true)


## Attacks the target when in range, otherwise closes in (or gives up when it may not move).
func _engage(target: int, can_move: bool) -> Vector3:
	_attack_target = target
	if _in_attack_range(target):
		_anchored = true
		if _attack_cooldown <= 0.0:
			_start_swing(target)
		return Vector3.ZERO
	if not can_move:
		return Vector3.ZERO
	return _seek(registry.position_of(target))


func _scan_for_target(scan_range: float) -> void:
	if _is_attackable(_attack_target) and registry.edge_distance(handle, _attack_target) <= scan_range * 1.25:
		return
	if _scan_timer > 0.0:
		return
	_scan_timer = BEHAVIOR_UPDATE_TIME
	_attack_target = registry.find_enemy(handle, scan_range)


func _seek(destination: Vector3) -> Vector3:
	var far_from_goal := _nav_goal == Vector3.INF or _flat_distance(destination, _nav_goal) > REPATH_DISTANCE
	if far_from_goal or (_agent.is_navigation_finished() and _repath_timer <= 0.0):
		_agent.target_position = destination
		_nav_goal = destination
		_repath_timer = BEHAVIOR_UPDATE_TIME
	if _agent.is_navigation_finished():
		return Vector3.ZERO
	var to_next := _agent.get_next_path_position() - global_position
	to_next.y = 0.0
	if to_next.length_squared() < 0.0001:
		return Vector3.ZERO
	return to_next.normalized() * move_speed()


func _arrived(order: UnitOrder) -> bool:
	var distance := _flat_distance(global_position, order.position)
	var radius := ARRIVAL_RADIUS
	if order.group != null:
		radius += ARRIVAL_SPACING * sqrt(order.group.arrived.size())
	var path_done := _nav_goal.is_equal_approx(order.position) and _agent.is_navigation_finished()
	var stuck := _stuck_time >= STUCK_ARRIVAL_TIME and distance <= STUCK_ARRIVAL_DISTANCE
	if distance > radius and not path_done and not stuck:
		return false
	if order.group != null:
		order.group.arrived[handle] = true
	return true


func _update_stuck(delta: float, desired: Vector3) -> void:
	var moving := Vector2(velocity.x, velocity.z).length()
	if desired.length_squared() > 0.01 and moving < move_speed() * 0.25:
		_stuck_time += delta
	else:
		_stuck_time = 0.0


func _on_velocity_computed(safe_velocity: Vector3) -> void:
	if _dead:
		return
	var planar := Vector3.ZERO if _anchored else safe_velocity
	velocity = Vector3(planar.x, 0.0, planar.z)
	# No gravity or floor: any rise (flying, a knock-up) is kept, collisions only push sideways
	var rise := global_position.y
	move_and_slide()
	global_position.y = rise
	registry.sync_unit(handle, global_position, rotation.y)


# --- Combat --------------------------------------------------------------------

func _start_swing(target: int) -> void:
	_swing_time = 0.0
	_swing_target = target
	_swing_landed = false
	_attack_cooldown = definition.attack_cooldown / attack_speed_factor()
	var modifier := _charge_attack_modifier()
	var swing_length := (definition.attack_point + definition.attack_backswing) / attack_speed_factor()
	var clip := UnitAnimations.ability_clip(_anim, modifier, "", UnitAnimations.variant(_anim, definition.attack_animation))
	if not _reflection.is_empty():
		clip = UnitAnimations.ability_clip(_anim, _reflection.ability, "_attack", clip)  # striking from the shadows
	_gesture_time = 0.0
	_play(clip, _anim.get_animation(clip).length / swing_length, 0.08)
	_anim.seek(0.0, true)


## Searing Arrows: the attack order's modifier, or any autocast one, if there's mana.
## Returns the ability charged into this swing, or null.
func _charge_attack_modifier() -> AbilityDefinition:
	_swing_bonus = 0.0
	_swing_color = Color(0, 0, 0, 0)
	var slot := -1
	if not orders.is_empty() and orders[0].type == UnitOrder.Type.ATTACK and orders[0].ability_slot >= 0:
		slot = orders[0].ability_slot
	else:
		for i in autocast.size():
			if autocast[i]:
				slot = i
				break
	var ability := ability_at(slot)
	if ability == null or ability_level(slot) < 1:
		return null
	var cost := mana_cost(slot)
	if mana < cost:
		return null
	mana -= cost
	_swing_bonus = ability.value(&"damage_bonus", ability_level(slot))
	_swing_color = ability.icon_color
	return ability


func _update_swing(delta: float) -> void:
	_swing_time += delta * attack_speed_factor()  # faster attacks swing faster too
	if not _swing_landed and _swing_time >= definition.attack_point:
		_swing_landed = true
		if _is_attackable(_swing_target):
			var damage := registry.attack_damage(handle, attack_damage()) + _swing_bonus
			if randf() * 100.0 < stats.effective(Stats.Stat.CRIT_CHANCE):
				damage *= 1.0 + stats.value(Stats.Stat.CRIT_DAMAGE) / 100.0
				critical_hit.emit(_swing_target, damage)
			if is_behind(_swing_target):
				damage *= 1.0 + stats.value(Stats.Stat.BACKSTAB_DAMAGE) / 100.0
			var on_hit := Callable()
			if _reflection.is_empty():
				_end_stealth(true)  # attacking reveals; an ambush from stealth speeds up the next attacks
			else:
				on_hit = _cripple.bind(_reflection.cripple)
				_spend_reflection()
			on_hit = _attack_landed.bind(on_hit, damage)  # what rides on every hit: effects, cleave, splits
			if registry.deliver_attack(handle, _swing_target, damage, definition, _swing_color, on_hit):
				gain_combo(definition.mana_per_hit)
	if _swing_time >= definition.attack_point + definition.attack_backswing:
		_swing_time = -1.0
		_swing_target = UnitRegistry.NONE


## An attack of this unit landed on `victim` for `damage`: what else it carried (`carried`, a
## Reflection cripple), its definition's attack effect (Brook's chill), then what its ultimates
## add while they last: a cleave around the victim (Wrath of the Vigil), blades passing through it
## (Reflection's splits).
func _attack_landed(victim: int, carried: Callable, damage := 0.0) -> void:
	if carried.is_valid():
		carried.call(victim)
	if definition.attack_effect != null and is_alive():
		definition.attack_effect.on_hit(self, victim)
	var now := registry.now()
	if not _cleave.is_empty() and now < float(_cleave.until):
		_cleave_hit(victim, damage)
	if not _split.is_empty() and now < float(_split.until):
		_split_hit(victim, damage)
	for power in worn_powers():
		power.on_attack_landed(self, victim, damage)


## The powers of the legendary and named items it wears (ItemPower).
func worn_powers() -> Array[ItemPower]:
	var powers: Array[ItemPower] = []
	for item in equipment:
		if item != null and item.power != null:
			powers.append(item.power)
	return powers


## It landed the killing blow on `victim`, which fell at `at` (UnitRegistry): its items' powers answer.
func on_kill(victim: int, at: Vector3) -> void:
	for power in worn_powers():
		power.on_kill(self, victim, at)


## For `seconds`, every attack also strikes the enemies within `radius` of its victim for `share` of
## its damage (Sven's cleave, in Wrath of the Vigil).
func cleave_attacks(radius: float, share: float, seconds: float, color := Color(1.0, 0.85, 0.4)) -> void:
	_cleave = {"radius": radius, "share": share, "until": registry.now() + seconds, "color": color}


## For `seconds`, every attack also passes through its victim along `lines` blades (one straight on,
## two or three fanned out), `length` meters long, hitting what they cross for `share` of the damage
## (Templar Assassin's Psi Blades, split; Reflection).
func split_attacks(lines: int, share: float, length: float, seconds: float, color := Color(0.95, 0.35, 0.45)) -> void:
	_split = {"lines": lines, "share": share, "length": length, "until": registry.now() + seconds, "color": color}


func _cleave_hit(victim: int, damage: float) -> void:
	if not registry.is_alive(victim) and registry.life_of(victim) == UnitRegistry.Life.FREE:
		return
	var at := registry.position_of(victim)
	for other in registry.query_radius(at, _cleave.radius):
		if other != victim and UnitRegistry.are_enemies(registry.team_of(other), team):
			registry.apply_damage(other, damage * float(_cleave.share), handle, false)
	SpellEffects.pulse(registry, Terrain.lift(at), _cleave.radius, _cleave.color, 0.25)


## The angles of a split's blades: one straight on, two either side of it, three both and straight.
const SPLIT_ANGLES := {1: [0.0], 2: [-0.32, 0.32], 3: [-0.45, 0.0, 0.45]}


func _split_hit(victim: int, damage: float) -> void:
	if registry.life_of(victim) == UnitRegistry.Life.FREE:
		return
	var at := registry.position_of(victim)
	var forward := Vector2(at.x - global_position.x, at.z - global_position.z)
	if forward.length() < 0.01:
		forward = Vector2(sin(rotation.y), cos(rotation.y))
	forward = forward.normalized()
	var length := float(_split.length)
	var hit := {}
	for angle: float in SPLIT_ANGLES.get(int(_split.lines), [0.0]):
		var direction := forward.rotated(angle)
		var start := Vector2(at.x, at.z)
		var end := start + direction * length
		for other in registry.query_radius(at + Vector3(direction.x, 0, direction.y) * length * 0.5, length * 0.5 + 1.0):
			if other == victim or hit.has(other) or not UnitRegistry.are_enemies(registry.team_of(other), team):
				continue
			var spot := registry.position_of(other)
			var flat := Vector2(spot.x, spot.z)
			if flat.distance_to(Geometry2D.get_closest_point_to_segment(flat, start, end)) <= 1.0 + registry.radius_of(other):
				hit[other] = true
				registry.apply_damage(other, damage * float(_split.share), handle, false)
		for step in 4:
			var along := start + direction * length * (step + 1) / 4.0
			SpellEffects.pulse(registry, Terrain.lift(Vector3(along.x, 0, along.y)), 0.6, _split.color, 0.15 + 0.04 * step)


## The unit was placed on a map: at a fresh start, or arriving with the party. Abilities that
## keep something at its side set it up (Maren calls Brook).
func on_placed() -> void:
	for slot in mini(ability_levels.size(), definition.abilities.size()):
		if ability_levels[slot] > 0:
			definition.abilities[slot].on_owner_placed(self, ability_levels[slot])


## An attack from Reflection landed: the illusion ends and a charge is used up.
func _spend_reflection() -> void:
	# The illusion fights on for the whole of it now, its blades splitting like hers (Reflection)
	_reflection.charges -= 1
	if _reflection.charges <= 0:
		_end_stealth(false)


## Shadow Cripple on `victim`: slowed, and bleeding more with every hit while it lasts.
func _cripple(victim: int, cripple: Dictionary) -> void:
	registry.add_effect(victim, &"shadow_cripple", cripple.time, handle,
			{"slow": cripple.slow, "dps": cripple.dps, "stacking": true})
	registry.flash(victim, Color(0.55, 0.2, 0.6))


# --- Presentation --------------------------------------------------------------

func _update_facing(delta: float) -> void:
	var look := Vector3.ZERO
	if _cast != null:
		look = _cast.point - global_position if _cast.target == UnitRegistry.NONE or not registry.is_alive(_cast.target) \
			else registry.position_of(_cast.target) - global_position
	elif _swing_time >= 0.0 and _is_attackable(_swing_target):
		look = registry.position_of(_swing_target) - global_position
	elif _anchored and _is_attackable(_attack_target):
		look = registry.position_of(_attack_target) - global_position
	elif Vector2(velocity.x, velocity.z).length_squared() > 0.25:
		look = velocity
	look.y = 0.0
	if look.length_squared() < 0.0001:
		return
	# KayKit models face +Z
	rotation.y = rotate_toward(rotation.y, atan2(look.x, look.z), definition.turn_rate * delta)


func _update_animation(delta: float) -> void:
	_gesture_time = maxf(_gesture_time - delta, 0.0)
	if _swing_time >= 0.0 or _cast != null:
		return
	var speed := Vector2(velocity.x, velocity.z).length()
	if speed > 0.4:
		_gesture_time = 0.0
		_play(&"move/Running_A", clampf(speed / RUN_ANIMATION_SPEED, 0.6, 1.4))
		_footsteps(delta, speed)
	elif _gesture_time <= 0.0:
		_play(&"general/Idle_A")


## A party hero's steps, heard at its feet (Sounds "footstep"), quicker as it runs faster.
func _footsteps(delta: float, speed: float) -> void:
	if ai or team != registry.player_team or UnitRegistry.kind_of(handle) != UnitRegistry.Kind.HERO:
		return
	_step_timer -= delta * clampf(speed / RUN_ANIMATION_SPEED, 0.6, 1.4)
	if _step_timer <= 0.0:
		_step_timer = STEP_TIME
		Sounds.play_at(&"footstep", global_position)


## Plays a one-off clip (a cast) from the start and lets it finish after the cast, unless
## the unit moves or attacks first.
func _play_gesture(clip: StringName, speed: float) -> void:
	_play(clip, speed, 0.08)
	_anim.seek(0.0, true)
	_gesture_time = _anim.current_animation_length / speed


## One blow of a multi-strike spell (Swift Slashes): restarts the ability's strike clip
## ("abilities/<id>_strike", else an attack), fitted into `seconds`.
func play_strike(ability: AbilityDefinition, seconds: float) -> void:
	var clip := UnitAnimations.ability_clip(_anim, ability, "_strike", UnitAnimations.variant(_anim, definition.attack_animation))
	_play(clip, _anim.get_animation(clip).length / maxf(seconds, 0.05), 0.05)
	_anim.seek(0.0, true)


func _play(animation_name: StringName, speed := 1.0, blend := 0.15) -> void:
	_anim.speed_scale = speed
	if _anim.current_animation != animation_name:
		_anim.play(animation_name, blend)


# --- Helpers -------------------------------------------------------------------

## Alive and in sight of the team (noh ShouldTarget / CBFollow drop units in the fog).
func _is_attackable(target: int) -> bool:
	return target != handle and registry.is_alive(target) and registry.can_see(team, target)


func _in_attack_range(target: int) -> bool:
	return registry.edge_distance(handle, target) <= attack_range()


## How far its attacks reach: its kind's, plus what its stats add (Tamsin's Strength).
func attack_range() -> float:
	return definition.attack_range + (stats.value(Stats.Stat.ATTACK_RANGE) if stats != null else 0.0)


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
