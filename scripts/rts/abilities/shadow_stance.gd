extends AbilityDefinition

## NoH Fayde, Ability_Fade3 "Shadow Stance" (game/heroes/fade/ability_03): instantly
## disjoints (projectiles in flight miss), then for {duration} seconds every attack misses
## the caster and it moves {move_speed}% faster.

const SHADOW := Color(0.3, 0.15, 0.35, 0.8)


func cast(spell: SpellCast) -> void:
	var caster := spell.caster
	caster.disjoint()
	var bonus := caster.stats.value(Stats.Stat.MOVE_SPEED) * spell.value(&"move_speed") / 100.0
	caster.add_buff(&"shadow_stance", display_name, icon_glyph, icon_color,
			"Attacks miss; +%d%% move speed." % roundi(spell.value(&"move_speed")), spell.value(&"duration"),
			{Stats.Stat.MOVE_SPEED: bonus}, 100.0)
	SpellEffects.pulse(spell.registry, caster.global_position, 1.4, SHADOW, 0.4)
