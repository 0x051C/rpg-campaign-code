extends AbilityDefinition

## DotaCraft potm_searing_arrows: an attack modifier. Cast it on an enemy to attack
## with burning arrows, or right-click its button to autocast it on every attack.
## Each searing arrow costs mana and adds damage.

const FIRE := Color(1.0, 0.45, 0.1)


func bonus_damage(level: int) -> float:
	return value(&"damage_bonus", level)


## Attack modifiers reach as far as the hero's attack, not a cast range.
func draw_targeting(indicator: TargetingIndicator, spell: SpellCast) -> void:
	var caster := spell.caster
	indicator.circle(caster.global_position, caster.definition.attack_range + caster.definition.radius, FIRE * Color(1, 1, 1, 0.5), 1.5)
	if indicator.hover != UnitRegistry.NONE:
		var valid := check_target(spell, indicator.hover).is_empty()
		indicator.unit_ring(indicator.hover, FIRE if valid else TargetingIndicator.INVALID_COLOR)
