extends ItemPower

## The Vigil Lantern: Holy Light also shields the one it lights, no damage for {time} seconds.

const COLOR := Color(1.0, 0.9, 0.55, 0.6)


func on_cast(unit: Unit, ability: AbilityDefinition, spell: SpellCast) -> void:
	if ability.id() != &"paladin_holy_light":
		return
	var friend := unit.registry.unit_of(spell.target)
	if friend != null and friend.is_alive():
		friend.shield(value(&"time"), COLOR)
