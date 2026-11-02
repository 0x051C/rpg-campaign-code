class_name AttackEffect
extends Resource

## What a unit's attacks do when they land, on top of their damage: an attack modifier, like
## NoH's (Frostwolf's Skull: "on attack, applies Freeze"). A UnitDefinition's `attack_effect`.
## Heroes and summons only: creeps attack in the native core.


## The attack from `attacker` landed on `victim` (a projectile: when it arrived).
func on_hit(_attacker: Unit, _victim: int) -> void:
	pass
