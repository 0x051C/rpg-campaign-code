@tool
class_name Shrine
extends Node3D

## A shrine by the road, Diablo's (DIRECTION.md 5): when a hero of the party comes close, it blesses
## the whole party for a while (more armor, faster attacks, mana, speed) and goes dark. The campaign
## remembers it, so it stays dark after a load or a return. A pedestal with a light until there's a
## model of its own.

enum Blessing { IRON, HUNT, WELLS, HASTE }

const PEDESTAL := preload("res://assets/environment/dungeon/Pedestal2.glb")
const REACH := 2.8
const CHECK_TIME := 0.25
const BUFF := &"shrine"
## Blessing -> name, glyph, color, what it does, bonuses.
const BLESSINGS := {
	Blessing.IRON: ["Shrine of Iron", "Ir", Color(0.75, 0.8, 0.9), "6 more armor.", {Stats.Stat.ARMOR: 6.0}],
	Blessing.HUNT: ["Shrine of the Hunt", "Hu", Color(1.0, 0.6, 0.3), "Attacks a quarter faster.", {Stats.Stat.ATTACK_SPEED: 25.0}],
	Blessing.WELLS: ["Shrine of Wells", "We", Color(0.4, 0.65, 1.0), "Mana refilled, and 3 more mana a second.",
			{Stats.Stat.MANA_REGEN: 3.0}],
	Blessing.HASTE: ["Shrine of Haste", "Ha", Color(0.6, 1.0, 0.6), "One more meter a second on foot.", {Stats.Stat.MOVE_SPEED: 1.0}],
}

@export var blessing := Blessing.IRON
@export var duration := 120.0

var used := false

var _light: OmniLight3D
var _timer := 0.0


func _ready() -> void:
	_build_visual()
	if Engine.is_editor_hint():
		return
	Simulation.join(self, Simulation.Order.TRIGGERS)
	if Campaign.current != null and Campaign.current.is_opened(self):
		_go_dark()


func _simulate(delta: float) -> void:
	if used:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = CHECK_TIME
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	if party == null:
		return
	for hero in party.heroes():
		if hero.is_alive() and Vector2(hero.global_position.x - global_position.x, hero.global_position.z - global_position.z).length() < REACH:
			bless(party)
			return


## Blesses every hero of the party, once.
func bless(party: PartyInventory) -> void:
	if used:
		return
	var entry: Array = BLESSINGS[blessing]
	for hero in party.heroes():
		hero.add_buff(BUFF, entry[0], entry[1], entry[2], entry[3], duration, entry[4])
		if blessing == Blessing.WELLS:
			hero.mana = hero.max_mana
	if party.commander != null:
		party.commander.show_message("%s: %s For %d seconds." % [entry[0], entry[3], int(duration)], entry[2])
	Sounds.play_at(&"news", global_position)
	Campaign.current.mark_opened(self)
	_go_dark()


func _go_dark() -> void:
	used = true
	if _light != null:
		_light.visible = false


func _build_visual() -> void:
	if get_child_count() > 0:
		return  # a model of its own
	var pedestal := PEDESTAL.instantiate()
	pedestal.scale = Vector3.ONE * 1.4
	add_child(pedestal)
	_light = OmniLight3D.new()
	_light.light_color = (BLESSINGS[blessing][2] as Color)
	_light.light_energy = 2.5
	_light.omni_range = 6.0
	_light.position = Vector3(0, 2.0, 0)
	add_child(_light)
