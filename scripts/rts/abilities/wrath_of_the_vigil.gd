extends AbilityDefinition

## Ser Aldith's ultimate (DIRECTION.md 6: Sven's God's Strength, with cleave): for `duration`
## seconds her attack damage grows by `damage_bonus`% of her own, and every blow cleaves into
## the enemies within `radius` of its victim for `cleave`% of its damage. A horde breaks on her.

const HOLY := Color(1.0, 0.82, 0.35)
const BUFF := &"wrath"


func cast(spell: SpellCast) -> void:
	var caster := spell.caster
	var duration := spell.value(&"duration")
	caster.remove_buff(BUFF)  # the bonus is a share of her damage without it
	var bonus := caster.attack_damage() * spell.value(&"damage_bonus") / 100.0
	caster.add_buff(BUFF, display_name, icon_glyph, icon_color,
			"+%d attack damage; blows cleave %d%% around their target." % [roundi(bonus), roundi(spell.value(&"cleave"))],
			duration, {Stats.Stat.ATTACK_DAMAGE: bonus})
	caster.cleave_attacks(radius, spell.value(&"cleave") / 100.0, duration, HOLY)
	SpellEffects.pillar(spell.registry, caster.global_position, HOLY, 1.0, 7.0, 0.8)
	SpellEffects.pulse(spell.registry, caster.global_position, radius * 2.0, HOLY, 0.6)


## A computer Aldith (Risen, the arena) calls it when enemies crowd her.
func ai_target(unit: Unit, _slot: int) -> Dictionary:
	return {"target": unit.handle} if AbilityDefinition.ai_enemies(unit, unit.global_position, 6.0).size() >= 3 else {}
