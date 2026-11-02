extends SceneTree
## The smith (DIRECTION.md 1): a reroll replaces one rolled line with another that fits; tempering
## raises an item's level and every rolled line with it; a line carried from one find to another
## scales to its level (onto a full item it must replace one); tokens are bought for gold, spent on
## the work, and kept with the party.

const CAP := preload("res://data/items/leather_cap.tres")
const BOOTS := preload("res://data/items/worn_boots.tres")

var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")

	# Reroll
	var cap := LootRoller.roll(CAP, 5, ItemDefinition.Rarity.MAGIC)
	var line: Stats.Stat = cap.rolled.keys()[0]
	var name_before := cap.display_name
	_check("a reroll", Forge.reroll(cap, line).is_empty())
	_check("replaces the line with another that fits, and the name follows", not cap.rolled.has(line) and cap.rolled.size() >= 1
			and cap.display_name != name_before and _consistent(cap))

	# Temper
	var rare := LootRoller.roll(BOOTS, 3, ItemDefinition.Rarity.RARE)
	var before := rare.rolled.duplicate()
	_check("tempering", Forge.temper(rare, 4).is_empty() and rare.item_level == 7)
	var grew := true
	for stat: Stats.Stat in before:
		grew = grew and rare.rolled[stat] >= before[stat]
	_check("raises every rolled line with the level", grew and _consistent(rare))

	# Carry a line over
	var source := LootRoller.roll(CAP, 9, ItemDefinition.Rarity.RARE)
	var target := LootRoller.roll(CAP, 4, ItemDefinition.Rarity.COMMON)
	var carried: Stats.Stat = source.rolled.keys()[0]
	_check("carried onto a plain find: it takes the line and turns magic", Forge.transfer(source, carried, target).is_empty()
			and target.rolled.has(carried) and target.rarity == ItemDefinition.Rarity.MAGIC and _consistent(target))
	_check("scaled to its level", target.rolled[carried] <= source.rolled[carried])
	var full := LootRoller.roll(CAP, 5, ItemDefinition.Rarity.RARE)
	while full.rolled.size() < 4:
		full = LootRoller.roll(CAP, 5, ItemDefinition.Rarity.RARE)
	var other := LootRoller.roll(CAP, 5, ItemDefinition.Rarity.MAGIC)
	var spare: Stats.Stat = -1
	for stat: Stats.Stat in other.rolled:
		if not full.rolled.has(stat):
			spare = stat
	if spare >= 0:
		_check("onto a full item it must replace a line", not Forge.transfer(other, spare, full).is_empty())
		var given_up: Stats.Stat = full.rolled.keys()[0]
		_check("and does, when told which", Forge.transfer(other, spare, full, given_up).is_empty()
				and full.rolled.has(spare) and not full.rolled.has(given_up) and full.rolled.size() == 4 and _consistent(full))

	# Tokens: bought, spent, kept
	var map: Node3D = support.call(&"open_map", self, ["maren"], "res://scenes/maps/story_template.tscn")
	await create_timer(0.3).timeout
	var party: PartyInventory = map.get_node("Party")
	var smith := Blacksmith.new()
	map.add_child(smith)
	party.gold = 40
	party.tokens = 0
	_check("a token for 15 gold", smith.buy_token().is_empty() and party.tokens == 1 and party.gold == 25)
	_check("work without enough tokens is refused", not smith.work(smith.temper_cost, Forge.temper.bind(rare, 2)).is_empty()
			and party.tokens == 1)
	_check("a reroll spends one", smith.work(smith.reroll_cost, Forge.reroll.bind(cap, cap.rolled.keys()[0])).is_empty()
			and party.tokens == 0)
	party.tokens = 3
	var state := party.save_state()
	party.tokens = 0
	party.load_state(state)
	_check("tokens are kept with the party", party.tokens == 3)
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


## Its bonuses are its base's plus its rolled lines.
func _consistent(item: ItemDefinition) -> bool:
	var stats := {}
	for stat: Stats.Stat in item.base_bonuses():
		stats[stat] = true
	for stat: Stats.Stat in item.rolled:
		stats[stat] = true
	for stat: Stats.Stat in item.bonuses:
		stats[stat] = true
	for stat: Stats.Stat in stats:
		var expected: float = item.base_item.bonuses.get(stat, 0.0) + item.rolled.get(stat, 0.0)
		if not is_equal_approx(item.bonuses.get(stat, 0.0), expected):
			return false
	return true


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
