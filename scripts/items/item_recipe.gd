class_name ItemRecipe
extends Resource

## One entry of the recipe book (ItemCatalog.recipes): the components the combine grid
## must hold to build `result` (noh: an item definition's component list). List a part
## twice to need two of it.

@export var result: ItemDefinition
@export var components: Array[ItemDefinition] = []
@export var allow_disassemble := true  ## noh AllowDisassemble
