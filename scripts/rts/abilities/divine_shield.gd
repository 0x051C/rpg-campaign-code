extends AbilityDefinition

## DotaCraft paladin_divine_shield: the caster can't be damaged for the duration.

const SHIELD := Color(1.0, 0.85, 0.4, 0.35)


const HOLY := Color(1.0, 0.85, 0.35)


## And when it ends (DIRECTION.md 6), the light breaks outwards: every enemy within `radius` is
## seared for {end_burst}, the undead twice that.
func cast(spell: SpellCast) -> void:
	var caster := spell.caster
	caster.shield(spell.value(&"shield_duration"), SHIELD)
	var burst := spell.value(&"end_burst")
	if burst <= 0.0:
		return
	var registry := spell.registry
	registry.get_tree().create_timer(spell.value(&"shield_duration"), false).timeout.connect(func() -> void:
		if not is_instance_valid(caster) or not caster.is_alive():
			return
		SpellEffects.pulse(registry, caster.global_position, radius, HOLY, 0.5)
		SpellEffects.pillar(registry, caster.global_position, HOLY, 0.8, 5.0, 0.5)
		for other in registry.query_radius(caster.global_position, radius):
			if UnitRegistry.are_enemies(registry.team_of(other), caster.team):
				registry.apply_damage(other, burst * (2.0 if registry.definition_of(other).undead else 1.0), caster.handle, false))
