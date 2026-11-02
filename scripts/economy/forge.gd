class_name Forge
extends RefCounted

## The smith's work on rolled items (DIRECTION.md 1, your note: upgrade, carry over good rolls, reroll):
## Diablo 3's Mystic and Kanai's Cube in one forge. Each takes tokens (Blacksmith).
## - reroll(): one rolled line is replaced by a new one that fits the slot (a prefix for a prefix).
## - temper(): the item rises in level, and every rolled line grows with it, keeping how good its roll was.
## - transfer(): a rolled line carried from one item to another, scaled to its level (the source goes
##   into the fire); onto a full item it replaces a line.
## Each returns "" or why not.

const MAX_ITEM_LEVEL := 20
## How many rolled lines an item can hold, by rarity; a plain item taking a line becomes magic.
const ROOM: Dictionary[ItemDefinition.Rarity, int] = {
	ItemDefinition.Rarity.COMMON: 1, ItemDefinition.Rarity.MAGIC: 2, ItemDefinition.Rarity.RARE: 4,
	ItemDefinition.Rarity.LEGENDARY: 3, ItemDefinition.Rarity.NAMED: 0,
}


## The affix a rolled line of `item` came from.
static func affix_of(item: ItemDefinition, stat: Stats.Stat) -> ItemAffix:
	var word: String = item.affix_words.get(stat, "")
	for affix in LootRoller.affixes():
		if affix.word == word and affix.stat == stat:
			return affix
	for affix in LootRoller.affixes():
		if affix.stat == stat:
			return affix
	return null


static func reroll(item: ItemDefinition, stat: Stats.Stat) -> String:
	if not item.rolled.has(stat):
		return "That line wasn't rolled; there's nothing to reroll"
	var old := affix_of(item, stat)
	var suffix := old.suffix if old != null else randf() < 0.5
	var candidates: Array[ItemAffix] = []
	for affix in LootRoller.affixes():
		if affix.suffix == suffix and affix.fits(item) and affix.stat != stat and not item.rolled.has(affix.stat):
			candidates.append(affix)
	if candidates.is_empty():
		return "Nothing else would take on this item"
	_remove(item, stat)
	var fresh: ItemAffix = candidates.pick_random()
	_add(item, fresh, fresh.roll(item.item_level))
	_rename(item)
	return ""


static func temper(item: ItemDefinition, levels: int) -> String:
	if item.base_item == null:
		return "Only found items can be tempered"
	if item.item_level >= MAX_ITEM_LEVEL:
		return "It won't take any more tempering"
	var to := mini(item.item_level + levels, MAX_ITEM_LEVEL)
	for stat: Stats.Stat in item.rolled.keys():
		var affix := affix_of(item, stat)
		if affix == null:
			continue
		var amount := scaled(affix, item.rolled[stat], item.item_level, to)
		item.bonuses[stat] = item.bonuses.get(stat, 0.0) - item.rolled[stat] + amount
		item.rolled[stat] = amount
	item.item_level = to
	return ""


## Moves `stat`'s line from `source` to `target` (replacing `replace` there if it's full; -1: none).
static func transfer(source: ItemDefinition, stat: Stats.Stat, target: ItemDefinition, replace := -1) -> String:
	if source == target:
		return "Pick another item to carry it to"
	if not source.rolled.has(stat):
		return "That line wasn't rolled"
	if target.base_item == null:
		return "Only found items take new lines"
	var affix := affix_of(source, stat)
	if affix == null or not affix.fits(target):
		return "That line won't take on a %s" % ItemDefinition.SLOT_NAMES[target.slot].to_lower()
	if target.rolled.has(stat) and replace != stat:
		return "It already has that line; replace it to carry this one over"
	if replace >= 0:
		if not target.rolled.has(replace as Stats.Stat):
			return "No such line to replace"
		_remove(target, replace as Stats.Stat)
	elif target.rolled.size() >= ROOM.get(target.rarity, 0):
		return "It has no room: pick a line of it to replace"
	_add(target, affix, scaled(affix, source.rolled[stat], source.item_level, target.item_level))
	if target.rarity == ItemDefinition.Rarity.COMMON:
		target.rarity = ItemDefinition.Rarity.MAGIC
	_rename(target)
	return ""


## A rolled `amount` of `affix` at item level `from`, as it would be at `to`, just as good a roll.
static func scaled(affix: ItemAffix, amount: float, from: int, to: int) -> float:
	var at_from := affix.value + affix.per_level * (from - 1)
	var at_to := affix.value + affix.per_level * (to - 1)
	var result := amount * at_to / maxf(at_from, 0.001)
	return snappedf(result, 0.05) if absf(affix.value) < 1.0 else maxf(roundf(result), 1.0)


static func _remove(item: ItemDefinition, stat: Stats.Stat) -> void:
	item.bonuses[stat] = item.bonuses.get(stat, 0.0) - item.rolled[stat]
	if is_zero_approx(item.bonuses[stat]):
		item.bonuses.erase(stat)
	item.rolled.erase(stat)
	item.affix_words.erase(stat)


static func _add(item: ItemDefinition, affix: ItemAffix, amount: float) -> void:
	item.rolled[affix.stat] = amount
	item.bonuses[affix.stat] = item.bonuses.get(affix.stat, 0.0) + amount
	item.affix_words[affix.stat] = affix.word


## A magic item is named after its affixes: after the smith's work, after its new ones.
static func _rename(item: ItemDefinition) -> void:
	if item.rarity != ItemDefinition.Rarity.MAGIC or item.base_item == null:
		return
	var prefix := ""
	var suffix := ""
	for stat: Stats.Stat in item.rolled:
		var affix := affix_of(item, stat)
		if affix == null:
			continue
		if affix.suffix and suffix.is_empty():
			suffix = affix.word
		elif not affix.suffix and prefix.is_empty():
			prefix = affix.word
	var name := item.base_item.display_name
	if not prefix.is_empty():
		name = "%s %s" % [prefix, name]
	if not suffix.is_empty():
		name = "%s %s" % [name, suffix]
	item.display_name = name
