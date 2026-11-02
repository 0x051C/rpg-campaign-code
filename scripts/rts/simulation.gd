class_name Simulation
extends Node

## The game's own clock: TICK_RATE fixed steps per game second, run from the frame loop instead
## of the physics step. Game rules that aren't physics (the unit registry, the fog of war, heroes'
## thinking, creep waves and camps, projectiles, triggers) step on it in a fixed order, so they
## don't depend on the physics rate or on what the frame rate does, and cost the same at any frame
## rate. Physics (bodies, move_and_slide, avoidance) stays in _physics_process.
##
## A system joins with `Simulation.join(self, order)` and gets `_simulate(delta)` every tick, lower
## orders first, then in the order they joined. It's skipped while it can't process (paused,
## disabled) or is outside the tree, and dropped once freed. Whatever is drawn between two ticks
## can use `alpha`: how far this frame is from the last tick to the next (UnitRegistry interpolates
## its creeps with it).
##
## Autoloaded as GameSimulation, first of the autoloads, so the others can join.

## After every tick: tests that watch the game's state tick by tick await it.
signal ticked

const TICK_RATE := 30  ## ticks per game second (noh's server ran 20, Dota 2's runs 30)
const TICK_TIME := 1.0 / TICK_RATE
const MAX_TICKS_PER_FRAME := 8  ## more than this behind: the game slows down instead of spiraling

## Who goes first within a tick.
enum Order {
	INPUT = -100,  ## replayed input (the test recorder)
	SIGHT = -10,  ## the fog of war: sight bits are fresh before anyone thinks
	UNITS = 0,  ## the unit registry: creeps
	BRAINS = 5,  ## computer heroes pick their orders
	HEROES = 10,  ## heroes and summons carry them out
	SPAWNS = 20,  ## creep waves, camps
	PROJECTILES = 30,
	TRIGGERS = 40,  ## map triggers, chests, pickups, quest steps
}

static var current: Simulation
static var ticks := 0  ## ticks since the game started
static var alpha := 0.0  ## 0-1: where this frame is between the last tick and the next

var _systems: Array = []  ## Nodes; untyped, so a freed one can still be looked at and dropped
var _orders := PackedInt32Array()
var _accumulator := 0.0


func _enter_tree() -> void:
	current = self
	process_priority = -1000  # the tick runs before anything this frame reads or draws it


func _exit_tree() -> void:
	if current == self:
		current = null


## `node` gets `_simulate(delta)` every tick from now on. Without a running game (the editor)
## nothing simulates, and this does nothing.
static func join(node: Node, order := 0) -> void:
	if current == null or current._systems.has(node):
		return
	var at := current._orders.size()
	while at > 0 and current._orders[at - 1] > order:
		at -= 1
	current._systems.insert(at, node)
	current._orders.insert(at, order)


static func leave(node: Node) -> void:
	if current == null:
		return
	var at := current._systems.find(node)
	if at >= 0:
		current._systems.remove_at(at)
		current._orders.remove_at(at)


func _process(delta: float) -> void:
	_accumulator += delta  # game time: already scaled by Engine.time_scale
	var limit := maxi(MAX_TICKS_PER_FRAME, ceili(Engine.time_scale * 2.0))  # sped up (tests): more per frame
	var count := 0
	while _accumulator >= TICK_TIME and count < limit:
		_accumulator -= TICK_TIME
		_tick()
		count += 1
	if _accumulator >= TICK_TIME:
		_accumulator = fmod(_accumulator, TICK_TIME)
	alpha = _accumulator / TICK_TIME


func _tick() -> void:
	ticks += 1
	# A copy: systems join and leave during the tick (a projectile launched, a trigger freed)
	for entry: Variant in _systems.duplicate():
		if not is_instance_valid(entry):
			continue
		var system := entry as Node
		if system.is_inside_tree() and not system.is_queued_for_deletion() and system.can_process():
			system.call(&"_simulate", TICK_TIME)
	for i in range(_systems.size() - 1, -1, -1):
		if not is_instance_valid(_systems[i]):
			_systems.remove_at(i)
			_orders.remove_at(i)
	ticked.emit()
