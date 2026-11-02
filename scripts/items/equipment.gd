class_name Equipment
extends RefCounted

## A hero's equipment slots: the slots from STATS_AND_ITEMS.md plus Weapon, Chest and
## Neck, and four rings. Unit.equipment holds one item (or null) per entry.

const SLOTS: Array[ItemDefinition.Slot] = [
	ItemDefinition.Slot.WEAPON,
	ItemDefinition.Slot.HEAD,
	ItemDefinition.Slot.SHOULDERS,
	ItemDefinition.Slot.CHEST,
	ItemDefinition.Slot.ARMS,
	ItemDefinition.Slot.HANDS,
	ItemDefinition.Slot.LEGS,
	ItemDefinition.Slot.BOOTS,
	ItemDefinition.Slot.NECK,
	ItemDefinition.Slot.RING,
	ItemDefinition.Slot.RING,
	ItemDefinition.Slot.RING,
	ItemDefinition.Slot.RING,
]
const WEAPON := 0


static func count() -> int:
	return SLOTS.size()


static func fits(index: int, item: ItemDefinition) -> bool:
	return item != null and index >= 0 and index < SLOTS.size() and SLOTS[index] == item.slot


static func slot_name(index: int) -> String:
	return ItemDefinition.SLOT_NAMES[SLOTS[index]]


## Where `item` goes in `worn`: the first free matching slot, else the first matching one
## (whose item it would replace), else -1.
static func place_for(worn: Array[ItemDefinition], item: ItemDefinition) -> int:
	var taken := -1
	for index in SLOTS.size():
		if not fits(index, item):
			continue
		if worn[index] == null:
			return index
		if taken < 0:
			taken = index
	return taken
