extends ItemPower

## Brand of the Vigil: while Wrath of the Vigil lasts, what its cleave reaches catches fire, {dps} fire
## damage a second for {time} seconds.

const COLOR := Color(1.0, 0.5, 0.15)


func on_attack_landed(unit: Unit, victim: int, _damage: float) -> void:
	var cleave: Dictionary = unit.get(&"_cleave")
	if cleave.is_empty() or unit.registry.now() >= float(cleave.until):
		return
	var registry := unit.registry
	if registry.life_of(victim) == UnitRegistry.Life.FREE:
		return
	for other in registry.query_radius(registry.position_of(victim), float(cleave.radius)):
		if UnitRegistry.are_enemies(registry.team_of(other), unit.team):
			registry.add_effect(other, &"vigil_fire", value(&"time"), unit.handle, {"dps": value(&"dps")})
			registry.flash(other, COLOR)
