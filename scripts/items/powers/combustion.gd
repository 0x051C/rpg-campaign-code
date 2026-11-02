extends ItemPower

## The Ashen Harrow: what its wielder kills bursts into flame, {damage} fire damage to the enemies
## within {radius} m.

const COLOR := Color(1.0, 0.45, 0.12)


func on_kill(unit: Unit, victim: int, at: Vector3) -> void:
	var registry := unit.registry
	SpellEffects.pulse(registry, Terrain.lift(at), value(&"radius"), COLOR, 0.35)
	Sounds.play_at(&"fire", at)
	for other in registry.query_radius(at, value(&"radius")):
		if other != victim and UnitRegistry.are_enemies(registry.team_of(other), unit.team):
			registry.apply_damage(other, value(&"damage"), unit.handle, false)
