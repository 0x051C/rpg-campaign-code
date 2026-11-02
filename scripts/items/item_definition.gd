class_name ItemDefinition
extends Resource

## An item (STATS_AND_ITEMS.md): worn in one equipment slot, it adds its stat bonuses to
## the hero; a weapon also sets the hero's attack type, and an item with an ability puts
## it on the hero's item bar. Recipes that build items live in the catalog's recipe book.

enum Slot { NONE, WEAPON, HEAD, SHOULDERS, CHEST, ARMS, HANDS, LEGS, BOOTS, NECK, RING }
## Diablo's colors (DIRECTION.md 1): a base as it is, magic with an affix or two, rare with three or four;
## legendary (an aspect that changes a spell) later; named items (the recipes' parts and results) apart.
enum Rarity { COMMON, MAGIC, RARE, LEGENDARY, NAMED }

const RARITY_NAMES: Dictionary[Rarity, String] = {
	Rarity.COMMON: "", Rarity.MAGIC: "Magic", Rarity.RARE: "Rare", Rarity.LEGENDARY: "Legendary", Rarity.NAMED: "",
}
const RARITY_COLORS: Dictionary[Rarity, Color] = {
	Rarity.COMMON: Color(0.92, 0.92, 0.92), Rarity.MAGIC: Color(0.45, 0.6, 1.0), Rarity.RARE: Color(1.0, 0.86, 0.3),
	Rarity.LEGENDARY: Color(1.0, 0.55, 0.15), Rarity.NAMED: Color(0.82, 0.68, 0.45),
}
## A rolled item is worth this much more than its bonuses alone say.
const RARITY_VALUE: Dictionary[Rarity, float] = {
	Rarity.COMMON: 1.0, Rarity.MAGIC: 1.15, Rarity.RARE: 1.35, Rarity.LEGENDARY: 1.8, Rarity.NAMED: 1.0,
}

const SLOT_NAMES: Dictionary[Slot, String] = {
	Slot.NONE: "Component",
	Slot.WEAPON: "Weapon",
	Slot.HEAD: "Head",
	Slot.SHOULDERS: "Shoulders",
	Slot.CHEST: "Chest",
	Slot.ARMS: "Arms",
	Slot.HANDS: "Hands",
	Slot.LEGS: "Legs",
	Slot.BOOTS: "Boots",
	Slot.NECK: "Neck",
	Slot.RING: "Ring",
}

@export var display_name := "Item"
@export_multiline var description := ""
@export var icon_glyph := "?"
@export var icon_color := Color.GRAY
## Where it is worn; NONE for parts that are only good for combining.
@export var slot := Slot.NONE
@export var weight := 1.0
@export var bonuses: Dictionary[Stats.Stat, float] = {}
## Weapons: the wearer's attacks become this type.
@export var attack_type: AttackType
## Goes on the wearer's item bar: cast like a spell, or an aura that just works.
@export var ability: AbilityDefinition
## What a merchant asks for it, in gold; 0 works it out from its bonuses (value()).
@export var price := 0

## What it does besides its stats (a legendary's, or a named item's like the Twin Brands): ItemPower.
@export var power: ItemPower

@export_group("Rolled")
## Set on a rolled copy (LootRoller): its rarity, the level of what dropped it, the base it was rolled
## from, and which of its bonuses the affixes gave (shown apart from the base's own).
@export var rarity := Rarity.COMMON
@export var item_level := 0
@export var base_item: ItemDefinition
@export var rolled: Dictionary[Stats.Stat, float] = {}
## The affix word each rolled line came from ("Sturdy", "of the Bear"): its name, and the smith's work (Forge).
@export var affix_words: Dictionary[Stats.Stat, String] = {}

## Gold per point of each bonus, for items without a price of their own.
const VALUE_PER_POINT := {
	Stats.Stat.STRENGTH: 9.0, Stats.Stat.DEXTERITY: 9.0, Stats.Stat.INTELLIGENCE: 9.0, Stats.Stat.WILLPOWER: 9.0,
	Stats.Stat.MAX_HEALTH: 0.25, Stats.Stat.MAX_MANA: 0.3, Stats.Stat.HEALTH_REGEN: 14.0, Stats.Stat.MANA_REGEN: 18.0,
	Stats.Stat.ATTACK_DAMAGE: 4.0, Stats.Stat.ARMOR: 12.0, Stats.Stat.MOVE_SPEED: 30.0,
}


## What it's worth in gold: its price, or worked out from its bonuses and ability.
func value() -> int:
	if price > 0:
		return price
	var worth := 10.0
	for stat: Stats.Stat in bonuses:
		worth += absf(bonuses[stat]) * VALUE_PER_POINT.get(stat, 2.5)
	if ability != null:
		worth += 60.0
	worth *= RARITY_VALUE[rarity]
	return maxi(5, int(snappedf(worth, 5.0)))


## The color its name shows in (rarity).
func name_color() -> Color:
	return RARITY_COLORS[rarity]


## The bonuses its base has, without what the affixes added.
func base_bonuses() -> Dictionary[Stats.Stat, float]:
	if base_item == null:
		return bonuses
	return base_item.bonuses


func is_wearable() -> bool:
	return slot != Slot.NONE
