class_name UnitOrder
extends RefCounted

## One entry of a player unit's order queue (noh: SUnitCommand turned into an
## IBehavior). Targets are UnitRegistry handles, so an order can aim at a hero or a
## creep. CAST orders carry the ability slot, like noh's GAME_CMD_ABILITY_* commands.

enum Type { MOVE, ATTACK_MOVE, ATTACK, FOLLOW, PATROL, HOLD, CAST, TALK, PICKUP }


## Units sent to the same point by one command share a group, so late arrivals
## can stop short of a spot that is already crowded.
class Group extends RefCounted:
	var arrived: Dictionary[int, bool] = {}


var type: Type
var position := Vector3.ZERO  ## the destination, or a unit target's last known position
var target := UnitRegistry.NONE
var group: Group
var patrol_origin := Vector3.ZERO
var ability_slot := -1  ## CAST, or an ATTACK that uses an attack-modifier ability
var aggro_triggered := false  ## an ATTACK pulls (or sheds) creep aggro once, like noh CBAttack
var item: ItemPickup  ## PICKUP: what to walk to and pick up


static func to_point(order_type: Type, destination: Vector3, order_group: Group = null) -> UnitOrder:
	var order := UnitOrder.new()
	order.type = order_type
	order.position = destination
	order.group = order_group
	return order


static func on_unit(order_type: Type, order_target: int, registry: UnitRegistry) -> UnitOrder:
	var order := UnitOrder.new()
	order.type = order_type
	order.target = order_target
	if registry.is_alive(order_target):
		order.position = registry.position_of(order_target)
	return order


static func pickup(pickup_item: ItemPickup) -> UnitOrder:
	var order := UnitOrder.new()
	order.type = Type.PICKUP
	order.item = pickup_item
	order.position = pickup_item.ground_spot()
	return order


static func cast(slot: int, order_target: int, point: Vector3) -> UnitOrder:
	var order := UnitOrder.new()
	order.type = Type.CAST
	order.ability_slot = slot
	order.target = order_target
	order.position = point
	return order


## Where the order points, following a living unit target while the player sees it.
func get_world_position(registry: UnitRegistry) -> Vector3:
	if registry.is_alive(target) and registry.player_sees(target):
		position = registry.position_of(target)
	return position


## Patrol legs alternate between the shared destination and the unit's own origin.
func turn_around(unit_handle: int) -> void:
	if group != null:
		group.arrived.erase(unit_handle)
	var destination := position
	position = patrol_origin
	patrol_origin = destination
