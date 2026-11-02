extends AbilityDefinition

## NoH Fayde, Ability_Fade1 "Cull" (game/heroes/fade/ability_01): a wide scythe sweep around
## the caster. Every enemy within the radius takes {damage} magic damage and, if it has
## mana, loses {mana_burn_percent}% of its maximum mana.

const SHADOW := Color(0.55, 0.12, 0.2, 0.85)


func cast(spell: SpellCast) -> void:
	var registry := spell.registry
	var caster := spell.caster
	var center := caster.global_position
	SpellEffects.pulse(registry, center, radius, SHADOW, 0.45)
	for victim in registry.query_radius(center, radius):
		if not UnitRegistry.are_enemies(registry.team_of(victim), caster.team):
			continue
		var burned := registry.unit_of(victim)
		if burned != null and burned.max_mana > 0.0:
			burned.mana = maxf(burned.mana - burned.max_mana * spell.value(&"mana_burn_percent") / 100.0, 0.0)
		registry.apply_damage(victim, spell.value(&"damage"), caster.handle, false)
		registry.flash(victim, SHADOW)
