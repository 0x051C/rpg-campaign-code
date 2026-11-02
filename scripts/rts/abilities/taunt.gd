extends AbilityDefinition

## NoH Legionnaire, Ability_Legionnaire1 "Taunt" (game/heroes/legionnaire/ability_01): every
## enemy within the radius is forced to attack the caster for {duration} seconds (heroes
## can't be ordered or cast meanwhile), and the caster braces, +{armor} armor for as long.

const ROAR := Color(0.85, 0.25, 0.15, 0.85)
const AI_CROWD := 3  ## the computer taunts this many enemies at once, or any hero


func cast(spell: SpellCast) -> void:
	var caster := spell.caster
	var registry := spell.registry
	var duration := spell.value(&"duration")
	caster.add_buff(&"taunting", "Taunting", icon_glyph, icon_color, "+%d armor." % roundi(spell.value(&"armor")),
			duration, {Stats.Stat.ARMOR: spell.value(&"armor")})
	SpellEffects.pulse(registry, caster.global_position, radius, ROAR, 0.5)
	for victim in registry.query_radius(caster.global_position, radius):
		if UnitRegistry.are_enemies(registry.team_of(victim), caster.team):
			registry.force_attack(victim, caster.handle, duration)
			registry.flash(victim, ROAR)


func ai_target(unit: Unit, _slot: int) -> Dictionary:
	var near := ai_enemies(unit, unit.global_position, radius)
	var heroes := near.filter(func(h: int) -> bool: return unit.registry.unit_of(h) != null)
	return {"point": unit.global_position} if near.size() >= AI_CROWD or not heroes.is_empty() else {}
