extends ItemPower

## The Gleaner's Sickle: its wielder's blows heal them for {share}% of the damage they do.


func on_attack_landed(unit: Unit, _victim: int, damage: float) -> void:
	if unit.is_alive():
		unit.registry.heal(unit.handle, damage * value(&"share") / 100.0)
