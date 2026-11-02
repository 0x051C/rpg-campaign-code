extends AbilityDefinition

## DotaCraft potm_starfall (vscripts/heroes/potm/starfall.lua): while channeling, a
## wave of stars strikes every enemy within radius each wave_interval seconds.

const STAR := Color(0.75, 0.85, 1.0, 0.95)
const IMPACT_DELAY := 0.4  ## stars land this long after the wave starts


func cast(spell: SpellCast) -> void:
	spell.timer = 0.0  # first wave right away


func channel(spell: SpellCast, delta: float) -> void:
	spell.timer -= delta
	if spell.timer > 0.0:
		return
	spell.timer = spell.value(&"wave_interval")
	var registry := spell.registry
	var damage := spell.value(&"wave_damage")
	for target in registry.query_radius(spell.caster.global_position, radius):
		if not UnitRegistry.are_enemies(registry.team_of(target), spell.caster.team):
			continue
		SpellEffects.fall(registry, registry.position_of(target), STAR, 0.3, 12.0, IMPACT_DELAY, SpellEffects.STAR)
		registry.get_tree().create_timer(IMPACT_DELAY).timeout.connect(
			registry.apply_damage.bind(target, damage, spell.caster.handle, false))
