extends AuraAbility

## Tamsin's Burning Arrows (STORY.md 6): DotaCraft's Searing Arrows and Trueshot Aura in one spell.
## As an attack modifier (cast it on an enemy, or autocast it) each arrow costs mana and burns for
## `damage_bonus` more; and while she knows it, the party's ranged attacks around her hit
## `damage_bonus_percent` harder (the aura: AuraAbility, RANGED_DAMAGE_PERCENT).

const FIRE := Color(1.0, 0.45, 0.1)


func bonus_damage(level: int) -> float:
	return value(&"damage_bonus", level)


## Attack modifiers reach as far as the hero's attack, not a cast range.
func draw_targeting(indicator: TargetingIndicator, spell: SpellCast) -> void:
	var caster := spell.caster
	indicator.circle(caster.global_position, caster.attack_range() + caster.definition.radius, FIRE * Color(1, 1, 1, 0.5), 1.5)
	if indicator.hover != UnitRegistry.NONE:
		var valid := check_target(spell, indicator.hover).is_empty()
		indicator.unit_ring(indicator.hover, FIRE if valid else TargetingIndicator.INVALID_COLOR)
