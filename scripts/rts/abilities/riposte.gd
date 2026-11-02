extends AbilityDefinition

## Rogue (after NoH's Swiftblade): for {duration} seconds the Rogue parries most attacks
## (+{parry_rating} parry rating). Every parried attack gives combo, like the Riposte passive.

const STEEL := Color(0.85, 0.9, 1.0, 0.8)


func cast(spell: SpellCast) -> void:
	var rating := spell.value(&"parry_rating")
	spell.caster.add_buff(&"riposte", "Riposte", "Rp", STEEL, "+%d parry rating." % roundi(rating),
			spell.value(&"duration"), {Stats.Stat.PARRY: rating})
	SpellEffects.pulse(spell.registry, spell.caster.global_position, 1.2, STEEL, 0.3)
