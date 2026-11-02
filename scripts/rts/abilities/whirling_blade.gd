extends AbilityDefinition

## NoH Legionnaire, Ability_Legionnaire3 "Whirling Blade" (game/heroes/legionnaire/ability_03):
## passive. Every attack about to hit the hero has a {chance}% chance to set off a spin that
## deals {damage} physical damage (armor counts, it can't be dodged) to every enemy around.


const SPIN := Color(0.85, 0.85, 0.9, 0.8)


## Unit.on_attacked: an attack from `source` is about to hit `unit`.
func on_owner_attacked(unit: Unit, slot: int, _source: int) -> void:
	var level := unit.ability_level(slot)
	if randf() * 100.0 >= value(&"chance", level):
		return
	var registry := unit.registry
	for victim in registry.query_radius(unit.global_position, radius):
		if UnitRegistry.are_enemies(registry.team_of(victim), unit.team):
			registry.apply_damage(victim, value(&"damage", level), unit.handle, true, false)
	unit.ability_cooldowns[slot] = cooldown_at(level)
	unit.play_ability_clip(self)
	SpellEffects.pulse(registry, unit.global_position, radius, SPIN, 0.35)
