class_name AttackType
extends Resource

## A StarCraft-style attack type: bonus damage against some armor types and nothing else,
## never a penalty. Units take theirs from their definition; heroes from their weapon,
## which works like a Warcraft III orb: it changes the attack type, not the model, the
## animations or the attack range. Units without one deal plain damage.

@export var display_name := "Normal"
@export var icon_glyph := "N"
@export var icon_color := Color.GRAY
@export var bonuses: Dictionary[Stats.Armor, float] = {}  ## armor type -> percent extra damage


## Damage factor against a unit of `armor` type.
static func multiplier_of(attack: AttackType, armor: Stats.Armor) -> float:
	return 1.0 + attack.bonuses.get(armor, 0.0) / 100.0 if attack != null else 1.0


## "This unit deals +30% damage against Light and Unarmored."
func describe() -> String:
	var by_amount: Dictionary[float, Array] = {}
	for armor in Stats.ARMOR_NAMES:
		var amount: float = bonuses.get(armor, 0.0)
		if amount > 0.0:
			if not by_amount.has(amount):
				by_amount[amount] = []
			by_amount[amount].append(Stats.ARMOR_NAMES[armor])
	if by_amount.is_empty():
		return "No bonus damage against any armor."
	var parts: Array[String] = []
	for amount in by_amount:
		var names: Array = by_amount[amount]
		var listed: String = names[0]
		if names.size() > 1:
			listed = ", ".join(names.slice(0, -1)) + " and " + str(names[-1])
		parts.append("+%s%% damage against %s" % [AbilityDefinition.format_number(amount), listed])
	return "This unit deals %s." % "; ".join(parts)
