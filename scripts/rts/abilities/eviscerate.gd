extends AbilityDefinition

## Rogue finisher: spends all of the Rogue's combo (mana) on one strike against an adjacent
## enemy: {base_damage} damage plus {damage_per_mana} for every point of mana spent. A spell,
## so it grows with spell damage (the Rogue's Dexterity) and ignores armor.

const BLOOD := Color(0.9, 0.2, 0.25, 0.9)


func cast(spell: SpellCast) -> void:
	var caster := spell.caster
	var spent := spell.mana_spent + caster.mana  # the cost, then everything else
	caster.mana = 0.0
	var damage := spell.value(&"base_damage") + spell.value(&"damage_per_mana") * spent
	spell.registry.apply_damage(spell.target, damage, caster.handle, false)
	SpellEffects.pulse(spell.registry, spell.registry.position_of(spell.target), 1.0, BLOOD, 0.35)
