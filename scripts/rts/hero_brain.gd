class_name HeroBrain
extends Node

## Plays a computer-controlled hero (Unit.ai), e.g. the hero a creep spawner sends instead
## of siege creeps (CreepWaves). It walks its spawner's lane like the creeps, attack-moving
## from waypoint to waypoint (noh CLane::GetNextWaypoint) and fighting what it meets; learns
## its spells as it gets skill points, ultimate first; and casts whichever spell's own rule
## (AbilityDefinition.ai_target) says now is the time.

const THINK_TIME := 0.25

var unit: Unit
var spawner: CreepSpawner

var _timer := 0.0
var _waypoint := Vector3.INF


func _ready() -> void:
	Simulation.join(self, Simulation.Order.BRAINS)


func _simulate(delta: float) -> void:
	if unit == null or not unit.is_alive() or not unit.registry.nav_ready:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = THINK_TIME
	_learn()
	if unit.is_busy():
		return
	if not _cast_something():
		_walk_lane()


## Spends skill points: a first level of the ultimate as soon as it can, then whichever
## spell has the fewest levels.
func _learn() -> void:
	while unit.skill_points > 0:
		var best := -1
		for slot in unit.definition.abilities.size():
			if not unit.can_learn(slot):
				continue
			if unit.ability_at(slot).ultimate and unit.ability_level(slot) == 0:
				best = slot
				break
			if best < 0 or unit.ability_level(slot) < unit.ability_level(best):
				best = slot
		if best < 0 or not unit.learn(best):
			return


func _cast_something() -> bool:
	for slot in unit.definition.abilities.size():
		var ability := unit.ability_at(slot)
		if ability == null or ability.is_passive() or not unit.ability_error(slot).is_empty():
			continue
		var aim := ability.ai_target(unit, slot)
		if aim.is_empty():
			continue
		var target: int = aim.get("target", UnitRegistry.NONE)
		var point: Vector3 = aim.get("point", unit.registry.position_of(target) if target != UnitRegistry.NONE else unit.global_position)
		unit.order_cast(slot, target, point, Unit.Queue.NONE)
		return true
	return false


## Keeps attack-moving to the lane's next waypoint; a new order only when that changes or
## the hero ran out of orders, so fights on the way aren't interrupted.
func _walk_lane() -> void:
	if spawner == null:
		return
	var next := spawner.next_waypoint(unit.global_position, _waypoint)
	if next != _waypoint or unit.orders.is_empty():
		_waypoint = next
		unit.order_attack_move(next, Unit.Queue.NONE)
