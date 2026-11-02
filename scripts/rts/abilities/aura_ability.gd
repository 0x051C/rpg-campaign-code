class_name AuraAbility
extends AbilityDefinition

## DotaCraft's passive auras (paladin_devotion_aura, potm_trueshot_aura,
## archmage_brilliance_aura): allies within `radius` of the hero get the bonus.
## Auras of the same kind don't stack; the registry keeps the strongest.

enum Stat { ARMOR, RANGED_DAMAGE_PERCENT, MANA_REGEN }

@export var stat := Stat.ARMOR
@export var amount_key: StringName = &"bonus"


func amount(level: int) -> float:
	return value(amount_key, level)
