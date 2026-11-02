class_name Blacksmith
extends Node

## The smith (DIRECTION.md 1): talking to its `host` opens the forge (BlacksmithWindow). He sells
## tokens for gold, and spends them on the party's found items (Forge): a reroll, a tempering, a line
## carried from one item to another.

@export var host: NeutralSpawn
@export var title := "The smith"
@export var token_price := 15
@export var reroll_cost := 1
@export var temper_cost := 2
@export var temper_levels := 2
@export var transfer_cost := 3

var _window: BlacksmithWindow


func _ready() -> void:
	_listen.call_deferred()


func _listen() -> void:
	var registry := get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	if registry != null:
		registry.talked_to.connect(_on_talked)
		registry.dialogue_finished.connect(_on_dialogue_finished)


func open() -> void:
	if is_instance_valid(_window):
		return
	_window = BlacksmithWindow.new()
	_window.smith = self
	get_tree().root.add_child(_window)


## A token for `token_price` gold; "" or why not.
func buy_token() -> String:
	var party := EconomyWindow.party()
	if party == null or not party.spend_gold(token_price):
		return "A token costs %d gold" % token_price
	party.tokens += 1
	Sounds.play(&"coin")
	return ""


## Spends `cost` tokens on `work` (a Callable returning "" or why not), if the party has them.
func work(cost: int, job: Callable) -> String:
	var party := EconomyWindow.party()
	if party == null or party.tokens < cost:
		return "That takes %d token%s" % [cost, "" if cost == 1 else "s"]
	var error: String = job.call()
	if error.is_empty():
		party.tokens -= cost
		Sounds.play_at(&"clunk", host.global_position if host != null else Vector3.ZERO)
		party.changed.emit()
	return error


func _on_talked(npc: int, _speaker: int) -> void:
	if host != null and npc == host.handle and (host.dialogue == null or host.dialogue.lines.is_empty()):
		open()


func _on_dialogue_finished(npc: int, _speaker: int) -> void:
	if host != null and npc == host.handle:
		open()
