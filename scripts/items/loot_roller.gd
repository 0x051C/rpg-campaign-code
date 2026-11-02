class_name LootRoller
extends RefCounted

## What monsters drop (DIRECTION.md 1), Diablo's way: most nothing, some gold, now and then an item
## rolled from a plain base (ItemCatalog.loot_bases) at the monster's level, magic or rare with
## affixes (data/loot/affixes.tres). Champions drop more and better. A kind can also drop a named
## part (UnitDefinition.named_drops), Dota's way: the ghouls of the north wood carry the Lightbrand.
##
## Placeholder numbers; LootRoller.rates scales them per map (UnitRegistry.loot_rate).

const AFFIXES := "res://data/loot/affixes.tres"
const LEGENDARY_DIR := "res://data/items/legendary/"
## A legendary's chance: from a champion (plus a little more each monster level), from a boss (a monster
## whose level was set by hand: the ghoul mother, the Risen, Corwin), and in a cache's chest.
const CHAMPION_LEGENDARY := 0.03
const LEGENDARY_PER_LEVEL := 0.004
const BOSS_LEGENDARY := 0.35
const CHEST_LEGENDARY := 0.06
const CATALOG := "res://data/items/catalog.tres"
const GOLD_CHANCE := 0.35
const ITEM_CHANCE := 0.06  ## plus ITEM_CHANCE_PER_LEVEL a monster level
const ITEM_CHANCE_PER_LEVEL := 0.005
const CHAMPION_ITEM_CHANCE := 0.75
const CHAMPION_EXTRA_ITEM := 0.25  ## a champion's chance of a second item
const GOLD_PER_LEVEL := 0.35
## Rarity weights: common, magic, rare.
const RARITY_WEIGHTS := [55, 35, 10]
const CHAMPION_RARITY_WEIGHTS := [15, 55, 30]
## A rare's made-up name: a first word, and a second by slot.
const RARE_FIRST: Array[String] = ["Dusk", "Grim", "Storm", "Bone", "Ash", "Raven", "Hollow", "Gleaner's", "Widow's", "Frost",
		"Barrow", "Ember", "Marrow", "Thorn", "Wheat", "Mourning", "Vigil", "Lantern"]
const RARE_SECOND: Dictionary[int, Array] = {
	ItemDefinition.Slot.WEAPON: ["Edge", "Brand", "Fang", "Song", "Bite", "Reaver"],
	ItemDefinition.Slot.HEAD: ["Cowl", "Crest", "Visage", "Brow", "Hood"],
	ItemDefinition.Slot.SHOULDERS: ["Mantle", "Spaulders", "Shoulders", "Yoke"],
	ItemDefinition.Slot.CHEST: ["Ward", "Hauberk", "Coat", "Shroud", "Jerkin"],
	ItemDefinition.Slot.ARMS: ["Bracers", "Wraps", "Guards", "Vambraces"],
	ItemDefinition.Slot.HANDS: ["Grip", "Fists", "Hands", "Claws"],
	ItemDefinition.Slot.LEGS: ["Greaves", "Legs", "Tassets", "Chausses"],
	ItemDefinition.Slot.BOOTS: ["Stride", "Tread", "March", "Walkers"],
	ItemDefinition.Slot.NECK: ["Charm", "Torc", "Locket", "Talisman"],
	ItemDefinition.Slot.RING: ["Band", "Loop", "Coil", "Circle", "Knot"],
}

static var _affixes: Array[ItemAffix] = []
static var _legendaries: Array[ItemDefinition] = []
static var _catalog: ItemCatalog


## What a monster of this kind drops when it dies: {items: Array[ItemDefinition], gold: int}.
## `rate` scales the chances (a map's loot_rate; 0: nothing).
static func drops_for(definition: UnitDefinition, rate := 1.0) -> Dictionary:
	var items: Array[ItemDefinition] = []
	var gold := 0
	if rate <= 0.0:
		return {"items": items, "gold": gold}
	var level := maxi(definition.monster_level, 1)
	var champion := definition.is_champion()
	if randf() < (1.0 if champion else GOLD_CHANCE * rate):
		gold = int(round(randi_range(1, 3) * (1.0 + GOLD_PER_LEVEL * (level - 1)) * (3.0 if champion else 1.0)))
	var chance := CHAMPION_ITEM_CHANCE if champion else ITEM_CHANCE + ITEM_CHANCE_PER_LEVEL * level
	if randf() < chance * rate:
		items.append(random_item(level, champion))
		if champion and randf() < CHAMPION_EXTRA_ITEM * rate:
			items.append(random_item(level, champion))
	var boss := definition.base == null and definition.monster_level > 0
	var legendary_chance := BOSS_LEGENDARY if boss else (CHAMPION_LEGENDARY + LEGENDARY_PER_LEVEL * level if champion else 0.0)
	if legendary_chance > 0.0 and randf() < legendary_chance * rate:
		items.append(random_legendary(level))
	var named := definition.named_drops
	if not named.is_empty() and randf() < definition.named_drop_chance * rate:
		items.append(named.pick_random())
	items = items.filter(func(item: ItemDefinition) -> bool: return item != null)
	return {"items": items, "gold": gold}


## A random base at `level`, its rarity rolled (better for a champion's drop).
static func random_item(level: int, champion := false) -> ItemDefinition:
	var bases := catalog().loot_bases
	if bases.is_empty():
		return null
	var weights: Array = CHAMPION_RARITY_WEIGHTS if champion else RARITY_WEIGHTS
	var pick := randi() % int(weights[0] + weights[1] + weights[2])
	var rarity := ItemDefinition.Rarity.COMMON
	if pick >= int(weights[0] + weights[1]):
		rarity = ItemDefinition.Rarity.RARE
	elif pick >= int(weights[0]):
		rarity = ItemDefinition.Rarity.MAGIC
	return roll(bases.pick_random(), level, rarity)


## `base` as a new item of `rarity` at item `level`: magic gets one or two affixes (a prefix, a
## suffix), rare three or four (up to two of each) and a made-up name. Common is the base at a level.
static func roll(base: ItemDefinition, level: int, rarity: ItemDefinition.Rarity) -> ItemDefinition:
	var item := base.duplicate() as ItemDefinition
	item.base_item = base
	item.item_level = maxi(level, 1)
	item.rarity = rarity
	item.bonuses = base.bonuses.duplicate()
	item.rolled = {}
	item.affix_words = {}
	item.price = 0  # worth what it rolled
	var count := 0
	match rarity:
		ItemDefinition.Rarity.MAGIC:
			count = randi_range(1, 2)
		ItemDefinition.Rarity.RARE:
			count = randi_range(3, 4)
		ItemDefinition.Rarity.LEGENDARY:
			count = 2  # Diablo 3's way: its power, its own stats, and a couple of rolls on top; it keeps its name
	var prefixes: Array[ItemAffix] = []
	var suffixes: Array[ItemAffix] = []
	var most := 1 if rarity == ItemDefinition.Rarity.MAGIC else 2
	for i in count:
		var want_suffix := randf() < 0.5
		if (want_suffix and suffixes.size() >= most) or (not want_suffix and prefixes.size() >= most):
			want_suffix = not want_suffix
		var affix := _pick_affix(item, want_suffix, prefixes + suffixes)
		if affix == null:
			affix = _pick_affix(item, not want_suffix, prefixes + suffixes)
		if affix == null:
			break
		(suffixes if affix.suffix else prefixes).append(affix)
		var amount := affix.roll(item.item_level)
		item.rolled[affix.stat] = item.rolled.get(affix.stat, 0.0) + amount
		item.bonuses[affix.stat] = item.bonuses.get(affix.stat, 0.0) + amount
		item.affix_words[affix.stat] = affix.word
	match rarity:
		ItemDefinition.Rarity.MAGIC:
			var name := base.display_name
			if not prefixes.is_empty():
				name = "%s %s" % [prefixes[0].word, name]
			if not suffixes.is_empty():
				name = "%s %s" % [name, suffixes[0].word]
			item.display_name = name
		ItemDefinition.Rarity.RARE:
			var second: Array = RARE_SECOND.get(base.slot, ["Thing"])
			item.display_name = "%s %s" % [RARE_FIRST.pick_random(), second.pick_random()]
	return item


static func _pick_affix(item: ItemDefinition, suffix: bool, taken: Array[ItemAffix]) -> ItemAffix:
	var candidates: Array[ItemAffix] = []
	var total := 0
	for affix in affixes():
		if affix.suffix == suffix and affix.fits(item) and not taken.has(affix):
			candidates.append(affix)
			total += affix.weight
	if total <= 0:
		return null
	var pick := randi() % total
	for affix in candidates:
		pick -= affix.weight
		if pick < 0:
			return affix
	return candidates.back()


## One of the legendaries (data/items/legendary), at `level`, with its two random affixes.
static func random_legendary(level: int) -> ItemDefinition:
	if _legendaries.is_empty():
		for file in ResourceLoader.list_directory(LEGENDARY_DIR):
			if file.ends_with(".tres"):
				var item := load(LEGENDARY_DIR + file) as ItemDefinition
				if item != null:
					_legendaries.append(item)
	if _legendaries.is_empty():
		return null
	return roll(_legendaries.pick_random(), level, ItemDefinition.Rarity.LEGENDARY)


static func affixes() -> Array[ItemAffix]:
	if _affixes.is_empty():
		var table := load(AFFIXES)
		if table != null:
			_affixes.assign(table.get(&"affixes"))
	return _affixes


static func catalog() -> ItemCatalog:
	if _catalog == null:
		_catalog = load(CATALOG) as ItemCatalog
	return _catalog
