class_name ItemAffix
extends Resource

## One line a random item can roll (DIRECTION.md 1): "Sturdy" (+armor) before the base's name, or
## "of the Bear" (+Strength) after it. Its size grows with the item's level; each roll lands within
## a fifth either side. The table is data/loot/affixes.tres (LootRoller).

@export var word := "Sturdy"
## After the base's name ("of the Bear") rather than before ("Sturdy").
@export var suffix := false
@export var stat := Stats.Stat.ARMOR
## At item level 1, and how much more each level after.
@export var value := 1.0
@export var per_level := 0.25
## The slots it rolls on (ItemDefinition.Slot); empty: any.
@export var slots: Array[int] = []
## How often it comes up against the others that fit.
@export var weight := 10
## Not before this item level.
@export var min_level := 1


func fits(item: ItemDefinition) -> bool:
	return item.item_level >= min_level and (slots.is_empty() or slots.has(item.slot))


## A roll at `level`, rounded to what the stat shows (whole points, or tenths for small ones).
func roll(level: int) -> float:
	var amount := (value + per_level * (level - 1)) * randf_range(0.8, 1.2)
	return snappedf(amount, 0.05) if absf(value) < 1.0 else maxf(roundf(amount), 1.0)
