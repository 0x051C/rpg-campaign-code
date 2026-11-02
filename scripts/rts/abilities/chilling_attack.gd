class_name ChillingAttack
extends AttackEffect

## Chills what it hits, NoH Frostwolf's Skull's Freeze (items/recipes/wolf_of_the_wilds,
## State_Item4G: 30% slower movement, 20% slower attacks, for 3 seconds), and gives the
## attacker's summoner mana: Brook's attacks feed Maren's spells.

const TINT := Color(0.55, 0.8, 1.0)

@export_range(0.0, 1.0) var slow := 0.3
@export_range(0.0, 1.0) var attack_slow := 0.2
@export var duration := 3.0
## Mana the summoner (the unit that called the attacker) gets per hit.
@export var summoner_mana := 0.0


func on_hit(attacker: Unit, victim: int) -> void:
	var registry := attacker.registry
	if not registry.is_alive(victim):
		return
	registry.add_effect(victim, &"chilled", duration, attacker.handle, {"slow": slow, "attack_slow": attack_slow})
	registry.flash(victim, TINT)
	Sounds.play_at(&"water", registry.position_of(victim))
	var summoner := attacker.summoner
	if summoner_mana > 0.0 and is_instance_valid(summoner) and summoner.is_alive():
		summoner.mana = minf(summoner.mana + summoner_mana, summoner.max_mana)
