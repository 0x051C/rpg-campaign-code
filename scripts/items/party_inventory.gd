class_name PartyInventory
extends Node

## The party's items (STATS_AND_ITEMS.md): one bag shared by all heroes, limited by total
## weight rather than item shapes; each hero's worn equipment; and the 2×3 combine grid,
## where recipe items assemble and come apart the way noh's inventory does.
##
## The bag and the grid count toward the weight limit, worn items don't. Only picking new
## items up is refused when it's too much (add()); taking an item off never is.

signal changed
## The combine grid built `item` from its components.
signal assembled(item: ItemDefinition)

enum Area { BAG, COMBINE, EQUIPMENT }

const GROUP := &"party_inventory"
const COMBINE_CELLS := 6  ## 2 rows of 3, like the HoN inventory
const GOOD_NEWS := Color(0.55, 1.0, 0.55)  ## message color for pickups and combines


## Where an item is: a bag index, a combine cell, or a hero's Equipment slot.
class Place:
	var area: Area
	var index: int
	var hero: Unit

	func _init(place_area: Area, place_index: int, place_hero: Unit = null) -> void:
		area = place_area
		index = place_index
		hero = place_hero


@export var commander: Commander
## Every item; the combine grid looks for recipes here.
@export var catalog: ItemCatalog
## Put in the bag when the map starts.
@export var starting_items: ItemCatalog
## kg the bag and the grid hold together, for the whole party.
@export var capacity := 90.0
@export var gold := 0
## The smith's tokens (Blacksmith): a morning at his anvil each, bought with gold or won in the Pit.
@export var tokens := 0
@export var bag: Array[ItemDefinition] = []
var combine: Array[ItemDefinition] = []


func _ready() -> void:
	add_to_group(GROUP)
	combine.resize(COMBINE_CELLS)
	if starting_items != null:
		for item in starting_items.items:
			bag.append(item)


## The party's living or fallen heroes.
func heroes() -> Array[Unit]:
	var found: Array[Unit] = []
	for handle in commander.heroes:
		var hero := commander.registry.unit_of(handle)
		if hero != null:
			found.append(hero)
	return found


func add_gold(amount: int) -> void:
	gold += amount
	changed.emit()


## Pays `amount`; false (and nothing paid) when the purse is short.
func spend_gold(amount: int) -> bool:
	if amount > gold:
		return false
	gold -= amount
	changed.emit()
	return true


## Takes the item at bag `index` out of the bag (sold, given away); null if there's none.
func take_from_bag(index: int) -> ItemDefinition:
	if index < 0 or index >= bag.size():
		return null
	var item := bag[index]
	bag.remove_at(index)
	changed.emit()
	return item


func save_state() -> Dictionary:
	return {"bag": SaveCodec.encode_resources(bag), "combine": SaveCodec.encode_resources(combine), "gold": gold, "tokens": tokens}


func load_state(data: Dictionary) -> void:
	SaveCodec.decode_resources_into(data.bag, bag)
	SaveCodec.decode_resources_into(data.combine, combine)
	combine.resize(COMBINE_CELLS)
	gold = data.get("gold", 0)
	tokens = data.get("tokens", 0)
	changed.emit()


## Whether the party has `item`: in the bag, the combine grid, or worn by one of its heroes; or,
## `or_built_into`, something a recipe made from it (the Lightbrand, gone into the Twin Brands).
func has_item(item: ItemDefinition, or_built_into := true) -> bool:
	if bag.has(item) or combine.has(item):
		return true
	for hero in heroes():
		if hero.equipment.has(item):
			return true
	if or_built_into:
		for result in LootRoller.catalog().uses_of(item):
			if result != item and has_item(result, true):
				return true
	return false


## Weight in the bag and the combine grid; worn items don't count.
func carried_weight() -> float:
	var total := 0.0
	for item in bag:
		total += item.weight
	for item in combine:
		if item != null:
			total += item.weight
	return total


## Picks `item` up into the bag; false when it's too heavy to carry as well.
func add(item: ItemDefinition) -> bool:
	if carried_weight() + item.weight > capacity + 0.0001:
		return false
	bag.append(item)
	changed.emit()
	return true


func item_at(place: Place) -> ItemDefinition:
	match place.area:
		Area.BAG:
			return bag[place.index] if place.index >= 0 and place.index < bag.size() else null
		Area.COMBINE:
			return combine[place.index] if place.index >= 0 and place.index < COMBINE_CELLS else null
		_:
			return place.hero.equipment[place.index] if place.hero != null else null


## Why `place` can't take `item`, or "".
func refusal(place: Place, item: ItemDefinition) -> String:
	if place.area == Area.EQUIPMENT and not Equipment.fits(place.index, item):
		if not item.is_wearable():
			return "%s can't be worn, only combined" % item.display_name
		return "%s goes in a %s slot" % [item.display_name, ItemDefinition.SLOT_NAMES[item.slot]]
	return ""


## Moves the item at `source` to `target`. Whatever was at the target goes back to the
## source if it fits there, else into the bag. Returns "" or why it didn't move.
func move(source: Place, target: Place) -> String:
	var item := item_at(source)
	if item == null:
		return "Nothing there"
	var refused := refusal(target, item)
	if not refused.is_empty():
		return refused
	var swapped_into_grid := false
	if target.area == Area.BAG:
		if source.area != Area.BAG:
			_put(source, null)
			bag.append(item)
	else:
		var displaced := item_at(target)
		if source.area == Area.BAG:
			bag.remove_at(source.index)
			if displaced != null:
				bag.append(displaced)
		elif displaced != null and refusal(source, displaced).is_empty():
			_put(source, displaced)
			swapped_into_grid = source.area == Area.COMBINE
		else:
			_put(source, null)
			if displaced != null:
				bag.append(displaced)
		_put(target, item)
	if target.area == Area.COMBINE:
		_assemble(target.index)
	if swapped_into_grid and combine[source.index] != null:
		_assemble(source.index)
	changed.emit()
	return ""


## Right-click shortcut: wear a bag item on `hero` (a component goes to the combine grid),
## take a worn item off, or take a combine item apart (else back to the bag).
func quick_move(source: Place, hero: Unit) -> String:
	var item := item_at(source)
	if item == null:
		return ""
	match source.area:
		Area.BAG:
			if item.is_wearable() and hero != null:
				return move(source, Place.new(Area.EQUIPMENT, Equipment.place_for(hero.equipment, item), hero))
			var free := combine.find(null)
			if free < 0:
				return "The combine grid is full"
			return move(source, Place.new(Area.COMBINE, free))
		Area.COMBINE:
			if can_disassemble(item):
				return disassemble(source.index)
			return move(source, Place.new(Area.BAG, 0))
	return move(source, Place.new(Area.BAG, 0))


## Whether the item can be taken apart in the combine grid.
func can_disassemble(item: ItemDefinition) -> bool:
	var recipe := catalog.recipe_for(item) if catalog != null and item != null else null
	return recipe != null and recipe.allow_disassemble


## noh IUnitEntity::DisassembleItem: the item in `cell` turns back into its components, if
## the grid has room for all of them.
func disassemble(cell: int) -> String:
	var item := combine[cell]
	if not can_disassemble(item):
		return "That can't be taken apart"
	var components := catalog.recipe_for(item).components
	var free := PackedInt32Array([cell])
	for other in COMBINE_CELLS:
		if combine[other] == null:
			free.append(other)
	if free.size() < components.size():
		return "Not enough room in the combine grid"
	for i in components.size():
		combine[free[i]] = components[i]
	if components.is_empty():
		combine[cell] = null
	changed.emit()
	return ""


func _put(place: Place, item: ItemDefinition) -> void:
	match place.area:
		Area.BAG:
			if item != null:
				bag.append(item)
		Area.COMBINE:
			combine[place.index] = item
		Area.EQUIPMENT:
			place.hero.set_equipped(place.index, item)


## noh IUnitEntity::CheckRecipes: when the item put in `cell` completes a recipe with
## what else is in the grid, the components become the item; a finished item can complete
## a bigger recipe in turn. Only recipes using the new item count, so taking an item apart
## doesn't put it straight back together.
func _assemble(cell: int) -> void:
	if catalog == null:
		return
	var trigger := cell
	while trigger >= 0:
		var built := -1
		for recipe in catalog.recipes:
			var cells := _find_components(recipe)
			if cells.is_empty() or not cells.has(trigger):
				continue
			for used in cells:
				combine[used] = null
			combine[trigger] = recipe.result
			built = trigger
			assembled.emit(recipe.result)
			break
		trigger = built


## Grid cells holding every component of `recipe`, one cell per component; empty if any
## is missing (noh CItemDefinition::Assemble).
func _find_components(recipe: ItemRecipe) -> PackedInt32Array:
	var used := PackedInt32Array()
	if recipe.result == null or recipe.components.is_empty():
		return used
	for component in recipe.components:
		var found := -1
		for cell in COMBINE_CELLS:
			if combine[cell] == component and not used.has(cell):
				found = cell
				break
		if found < 0:
			return PackedInt32Array()
		used.append(found)
	return used
