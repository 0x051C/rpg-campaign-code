class_name LastHitChallenge
extends Node

## A last-hitting challenge, as in Dota 2 (STORY.md: earning the night's gold): two sides of
## creeps fight, and only the enemies the party lands the killing blow on pay, `gold_per_last_hit`
## each. Heroes and their companions count (Brook too); the allied creeps' kills don't. start()
## sends the waves (`spawners`) for `duration` seconds, a counter shows how it goes, then the
## waves stop and `finished` says how it went.

signal finished(last_hits: int, gold: int)

const COIN := Color(1.0, 0.85, 0.3)

@export var duration := 120.0
@export var gold_per_last_hit := 3
@export var spawners: Array[CreepSpawner] = []
@export var enemy_team := 2

var last_hits := 0
var gold := 0
var running := false

var _left := 0.0
var _registry: UnitRegistry
var _layer: CanvasLayer
var _counter: Label


func _ready() -> void:
	Simulation.join(self, Simulation.Order.TRIGGERS)


## Starts it (connectable to any signal: a StoryScene's `finished`).
func start(_a: Variant = null, _b: Variant = null) -> void:
	if running:
		return
	_registry = get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	if _registry == null:
		return
	running = true
	_left = duration
	last_hits = 0
	gold = 0
	if not _registry.unit_died.is_connected(_on_died):
		_registry.unit_died.connect(_on_died)
	for spawner in spawners:
		spawner.activate()
	_show_counter()


func _simulate(delta: float) -> void:
	if not running:
		return
	_left -= delta
	_counter.text = "Last hits: %d   ·   %d gold   ·   %d:%02d" % [last_hits, gold, maxi(int(_left), 0) / 60, maxi(int(_left), 0) % 60]
	if _left <= 0.0:
		_end()


func _end() -> void:
	running = false
	for spawner in spawners:
		spawner.deactivate()
	_counter.text = "Done: %d last hits, %d gold." % [last_hits, gold]
	finished.emit(last_hits, gold)


func _on_died(handle: int, killer: int) -> void:
	if not running or _registry.team_of(handle) != enemy_team or not _is_party(killer):
		return
	last_hits += 1
	gold += gold_per_last_hit
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	if party != null:
		party.add_gold(gold_per_last_hit)
	Sounds.play_at(&"coin", _registry.position_of(handle))


## A party hero, or a companion of one (Brook's kills are Maren's).
func _is_party(handle: int) -> bool:
	var unit := _registry.unit_of(handle)
	if unit == null:
		return false
	var commander := get_tree().get_first_node_in_group(PartyInventory.GROUP).get(&"commander") as Commander
	if commander == null:
		return false
	if commander.heroes.has(handle):
		return true
	return unit.bound and is_instance_valid(unit.summoner) and commander.heroes.has(unit.summoner.handle)


func _show_counter() -> void:
	if _layer != null:
		return
	_layer = CanvasLayer.new()
	_layer.layer = 20
	add_child(_layer)
	_counter = Label.new()
	_counter.add_theme_font_size_override(&"font_size", 24)
	_counter.add_theme_color_override(&"font_color", COIN)
	_counter.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_counter.add_theme_constant_override(&"outline_size", 6)
	_counter.anchor_left = 0.5
	_counter.anchor_right = 0.5
	_counter.offset_left = -240.0
	_counter.offset_right = 240.0
	_counter.offset_top = 70.0
	_counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_layer.add_child(_counter)
