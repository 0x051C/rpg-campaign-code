extends AbilityDefinition

## DotaCraft paladin_resurrection (vscripts/heroes/paladin/resurrection.lua): raises
## up to max_units_resurrected allied corpses within radius of the caster, using the
## corpse system. Raised creeps rejoin their lane.

const HOLY := Color(1.0, 0.9, 0.5, 0.8)


func cast(spell: SpellCast) -> void:
	var registry := spell.registry
	var raised := registry.corpses.take(spell.caster.global_position, radius, spell.caster.team, int(spell.value(&"max_units_resurrected")))
	for corpse in raised:
		registry.spawn_npc(corpse.definition, spell.caster.team, corpse.position, registry.spawner_for_team(spell.caster.team))
		SpellEffects.pillar(registry, corpse.position, HOLY, 0.7, 8.0, 1.2)
	SpellEffects.pulse(registry, spell.caster.global_position, radius, HOLY, 0.8)
