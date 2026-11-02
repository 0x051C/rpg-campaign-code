class_name Vendor
extends Node

## Someone to trade with (STORY.md: the economy). Talking to its `host` opens the trade window.
## A merchant (`purse` -1) has gold without end and the hub's stock; a trader met on the road
## has a few small things and a limited purse for what the party sells. Buying takes an item
## off its stock, selling puts it on (the party can buy it back). Its stock and purse are
## remembered with the campaign.

@export var host: NeutralSpawn
@export var title := "Trade"
@export var stock: Array[ItemDefinition] = []
## Gold it can pay for what the party sells; -1: no end to it (a merchant).
@export var purse := -1
## Its prices: the items' values times this.
@export_range(0.5, 3.0, 0.05) var markup := 1.0
## What it pays: the items' values times this.
@export_range(0.05, 1.0, 0.05) var buys_at := 0.4

var _window: TradeWindow


func _ready() -> void:
	_listen.call_deferred()


func _listen() -> void:
	var state := _state()
	if not state.is_empty():
		var restored: Array[ItemDefinition] = []
		SaveCodec.decode_resources_into(state.stock, restored)
		stock = restored
		purse = state.purse
	var registry := get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	if registry != null:
		registry.talked_to.connect(_on_talked)
		registry.dialogue_finished.connect(_on_dialogue_finished)


func open() -> void:
	if is_instance_valid(_window):
		return
	_window = TradeWindow.new()
	_window.vendor = self
	get_tree().root.add_child(_window)


func price_of(item: ItemDefinition) -> int:
	return ceili(item.value() * markup)


func offer_for(item: ItemDefinition) -> int:
	return maxi(1, int(item.value() * buys_at))


## Buys stock item `index` for the party; "" or why not.
func buy(index: int) -> String:
	var party := EconomyWindow.party()
	if party == null or index < 0 or index >= stock.size():
		return "Nothing to buy"
	var item := stock[index]
	var price := price_of(item)
	if party.gold < price:
		return "Not enough gold"
	if not party.add(item):
		return "Too heavy: the party can't carry %s too" % item.display_name
	party.spend_gold(price)
	if purse >= 0:
		purse += price
	stock.remove_at(index)
	_save()
	return ""


## Sells the party's bag item `index`; "" or why not.
func sell(index: int) -> String:
	var party := EconomyWindow.party()
	if party == null or index < 0 or index >= party.bag.size():
		return "Nothing to sell"
	var offer := offer_for(party.bag[index])
	if purse >= 0 and purse < offer:
		return "%s can't afford it" % title
	var item := party.take_from_bag(index)
	party.add_gold(offer)
	if purse >= 0:
		purse -= offer
	stock.append(item)
	_save()
	return ""


func _state() -> Dictionary:
	if Campaign.current == null:
		return {}
	var vendors: Dictionary = Campaign.current.flags.get("vendors", {})
	return vendors.get(_key(), {})


func _save() -> void:
	var vendors: Dictionary = Campaign.current.flags.get_or_add("vendors", {})
	vendors[_key()] = {"stock": SaveCodec.encode_resources(stock), "purse": purse}


func _key() -> String:
	var map := get_tree().current_scene
	return "%s:%s" % [map.scene_file_path, map.get_path_to(self)]


## The host has had its say (its dialogue's lines), then makes the offer; one without lines
## makes it at once.
func _on_talked(npc: int, _speaker: int) -> void:
	if host != null and npc == host.handle and (host.dialogue == null or host.dialogue.lines.is_empty()):
		open()


func _on_dialogue_finished(npc: int, _speaker: int) -> void:
	if host != null and npc == host.handle:
		open()
