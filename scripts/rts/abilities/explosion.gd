extends AbilityDefinition

## The Mage's ultimate on Megumin's model (DIRECTION.md 6): she chants for the channel, then the
## biggest blast in the game goes off where she pointed: every enemy within `radius` takes
## {damage} fire damage and is knocked down for {knockdown} seconds. It takes everything out of her:
## she collapses for {exhaustion} seconds, helpless. Interrupted, nothing happens.

const FIRE := Color(1.0, 0.45, 0.12)
const WHITE_HOT := Color(1.0, 0.9, 0.7)


func cast(spell: SpellCast) -> void:
	SpellEffects.pulse(spell.registry, Terrain.lift(spell.point), radius, FIRE * Color(1, 1, 1, 0.6), channel_time_at(spell.level))


func end_channel(spell: SpellCast, interrupted: bool) -> void:
	if interrupted:
		return
	var registry := spell.registry
	var at := spell.point
	var lifted := Terrain.lift(at)
	SpellEffects.pillar(registry, lifted, WHITE_HOT, radius * 0.5, 14.0, 0.9)
	for i in 3:
		SpellEffects.pulse(registry, lifted, radius * (0.6 + 0.3 * i), FIRE, 0.4 + 0.25 * i)
	for i in 8:
		var angle := TAU * i / 8.0
		SpellEffects.fall(registry, lifted + Vector3(cos(angle), 0, sin(angle)) * radius * 0.6, FIRE, 0.6, 10.0, 0.3)
	for i in 3:
		Sounds.play_at(&"fire", at)
	for other in registry.query_radius(at, radius):
		if UnitRegistry.are_enemies(registry.team_of(other), spell.caster.team):
			registry.apply_damage(other, spell.value(&"damage"), spell.caster.handle, false)
			registry.add_effect(other, &"knocked_down", spell.value(&"knockdown"), spell.caster.handle, {"stun": true})
	registry.add_effect(spell.caster.handle, &"exhausted", spell.value(&"exhaustion"), spell.caster.handle, {"stun": true})


## A computer mage throws it at the thickest crowd it can reach.
func ai_target(unit: Unit, _slot: int) -> Dictionary:
	var foes := AbilityDefinition.ai_enemies(unit, unit.global_position, cast_range)
	if foes.size() < 6:
		return {}
	return {"point": unit.registry.position_of(foes[foes.size() / 2])}
