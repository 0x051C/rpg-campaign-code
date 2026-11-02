extends ItemPower

## The Rime Sigil: a spell with an area chills the enemies in it, {slow}% slower for {time} seconds.

const COLOR := Color(0.55, 0.8, 1.0)


func on_cast(unit: Unit, ability: AbilityDefinition, spell: SpellCast) -> void:
	if ability.radius <= 0.0:
		return
	var registry := unit.registry
	var center := registry.position_of(spell.target) if registry.is_alive(spell.target) else spell.point
	if ability.action == AbilityDefinition.Action.NO_TARGET:
		center = unit.global_position
	for other in registry.query_radius(center, ability.radius):
		if UnitRegistry.are_enemies(registry.team_of(other), unit.team):
			registry.add_effect(other, &"rime", value(&"time"), unit.handle, {"slow": value(&"slow") / 100.0, "attack_slow": value(&"slow") / 200.0})
			registry.flash(other, COLOR)
