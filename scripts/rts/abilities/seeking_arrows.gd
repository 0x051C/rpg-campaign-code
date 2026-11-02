extends AbilityDefinition

## Tamsin's Seeking Arrows (STORY.md 6; Emerald Warden's wolves, as arrows): a passive. Every spell she
## casts looses `arrows` arrows at the nearest enemies within `radius` she can see, `arrow_damage`
## each; with fewer enemies than arrows, some find the same one.

const COLOR := Color(0.6, 1.0, 0.55)
const SPEED := 26.0


func on_owner_cast(unit: Unit, level: int, cast_ability: AbilityDefinition) -> void:
	if cast_ability == self or not unit.is_alive():
		return
	var foes := AbilityDefinition.ai_enemies(unit, unit.global_position, radius)
	if foes.is_empty():
		return
	var damage := value(&"arrow_damage", level)
	for i in int(value(&"arrows", level)):
		Projectile.launch(unit.registry, unit.handle, foes[i % foes.size()], damage, SPEED, COLOR)
