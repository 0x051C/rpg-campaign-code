class_name ItemCatalog
extends Resource

## A list of items, e.g. a starting kit. The game's main catalog also holds the recipe
## book the combine grid builds from.

@export var items: Array[ItemDefinition] = []
@export var recipes: Array[ItemRecipe] = []
## The plain items random loot is rolled from (LootRoller): wearable, and no recipe's part or result.
@export var loot_bases: Array[ItemDefinition] = []


## The recipe that builds `item`, or null.
func recipe_for(item: ItemDefinition) -> ItemRecipe:
	for recipe in recipes:
		if recipe.result == item:
			return recipe
	return null


## The items `item` is a component of.
func uses_of(item: ItemDefinition) -> Array[ItemDefinition]:
	var found: Array[ItemDefinition] = []
	for recipe in recipes:
		if recipe.components.has(item) and not found.has(recipe.result):
			found.append(recipe.result)
	return found
