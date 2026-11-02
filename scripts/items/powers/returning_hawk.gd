extends ItemPower

## Hawkeye Bracers: Tamsin's Hawk turns where it lands and flies back through the line to her, striking
## again, {delay} seconds later.


func on_cast(unit: Unit, ability: AbilityDefinition, spell: SpellCast) -> void:
	if ability.id() != &"tamsin_hawk" or not ability.has_method(&"strike"):
		return
	var landed := spell.point
	var damage := spell.value(&"strike_damage")
	unit.registry.get_tree().create_timer(value(&"delay"), false).timeout.connect(func() -> void:
		if is_instance_valid(unit) and unit.is_alive():
			ability.call(&"strike", unit, landed, unit.global_position, damage))
