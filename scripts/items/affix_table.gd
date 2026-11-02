class_name AffixTable
extends Resource

## Every affix random items roll from (LootRoller, data/loot/affixes.tres). Edit them in the inspector:
## the word, the stat, how big at item level 1 and how much more each level, which slots, how often.

@export var affixes: Array[ItemAffix] = []
