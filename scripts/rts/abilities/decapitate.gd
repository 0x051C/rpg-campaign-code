extends AbilityDefinition

## NoH Legionnaire, Ability_Legionnaire4 "Decapitate" (game/heroes/legionnaire/ability_04):
## a mighty axe blow. A target below {kill_threshold} health dies outright; any other takes
## {damage} physical damage (armor counts, it can't be dodged).

const BLOOD := Color(0.75, 0.05, 0.05, 0.9)


func cast(spell: SpellCast) -> void:
	var registry := spell.registry
	var target := spell.target
	if not registry.is_alive(target):
		return
	if registry.health_of(target) < spell.value(&"kill_threshold"):
		registry.apply_damage(target, registry.health_of(target) + 1.0, spell.caster.handle, false)
		SpellEffects.pillar(registry, registry.position_of(target), BLOOD, 0.6, 3.0, 0.6)
	else:
		registry.apply_damage(target, spell.value(&"damage"), spell.caster.handle, true, false)
	registry.flash(target, BLOOD)


## Finishes off whatever it can kill outright, heroes first.
func ai_target(unit: Unit, slot: int) -> Dictionary:
	var registry := unit.registry
	var threshold := value(&"kill_threshold", unit.ability_level(slot))
	var best := UnitRegistry.NONE
	for enemy in ai_enemies(unit, unit.global_position, cast_range + 4.0):
		if registry.health_of(enemy) >= threshold:
			continue
		if registry.unit_of(enemy) != null:
			return {"target": enemy}
		if best == UnitRegistry.NONE and registry.max_health_of(enemy) >= threshold:
			best = enemy  # creeps only when they're big enough to be worth it
	return {"target": best} if best != UnitRegistry.NONE else {}
