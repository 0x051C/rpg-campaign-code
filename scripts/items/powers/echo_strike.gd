extends ItemPower

## The Twin Brands' echo (Dota's Echo Sabre): every {cooldown} seconds a blow strikes twice, and the
## second slows its victim {slow}% for {slow_time} seconds.

const COLOR := Color(1.0, 0.75, 0.4)


func on_attack_landed(unit: Unit, victim: int, damage: float) -> void:
	var registry := unit.registry
	if not registry.is_alive(victim) or not ItemPower.cooldown_ready(unit, &"echo_strike", value(&"cooldown")):
		return
	registry.apply_damage(victim, damage, unit.handle, true)
	registry.add_effect(victim, &"echoed", value(&"slow_time"), unit.handle, {"slow": value(&"slow") / 100.0})
	registry.flash(victim, COLOR)
