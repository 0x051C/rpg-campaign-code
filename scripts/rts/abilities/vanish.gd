extends AbilityDefinition

## Rogue (after NoH's Night Hound): turns invisible to the other teams for {duration}
## seconds; enemies lose track of the Rogue. Attacking out of it is an ambush: +{ambush_attack_speed}%
## attack speed for {ambush_duration} seconds, to build combo back up. Casting another spell
## just ends it.

const SHADOW := Color(0.25, 0.2, 0.35, 0.8)


func cast(spell: SpellCast) -> void:
	SpellEffects.pulse(spell.registry, spell.caster.global_position, 1.6, SHADOW, 0.5)
	spell.caster.vanish(spell.value(&"duration"), spell.value(&"ambush_attack_speed"), spell.value(&"ambush_duration"))
