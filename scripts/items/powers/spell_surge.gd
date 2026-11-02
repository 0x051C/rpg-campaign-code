extends ItemPower

## The Widow's Coil: every spell its wearer casts quickens their attacks, {attack_speed}% for {time}
## seconds.


func on_cast(unit: Unit, _ability: AbilityDefinition, _spell: SpellCast) -> void:
	unit.add_buff(&"widows_coil", "Widow's Coil", "WC", Color(0.75, 0.4, 0.9), "Attacks quickened after a spell.",
			value(&"time"), {Stats.Stat.ATTACK_SPEED: value(&"attack_speed")})
