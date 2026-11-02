class_name Stats
extends RefCounted

## Hero stats (STATS_AND_ITEMS.md): the four core stats, the derived stats combat uses and
## the rules between them. Every core stat gives every hero one general bonus, with
## Warcraft III's attribute values where Warcraft has the stat; the class's passives (one
## small effect each) and items add the rest.
##
## Rating stats (evasion, crit, resistances, mana cost reduction) have diminishing returns:
## a rating r gives r / (100 + r) percent, so 100 rating is 50% and nothing reaches 100%.

## Saved by number in .tres files: only ever add new stats at the end.
enum Stat {
	STRENGTH,
	DEXTERITY,
	INTELLIGENCE,
	WILLPOWER,
	MAX_HEALTH,
	HEALTH_REGEN,
	MAX_MANA,
	MANA_REGEN,
	ATTACK_DAMAGE,
	ATTACK_SPEED,  ## percent faster attacks
	ARMOR,  ## flat damage taken off every hit
	EVASION,  ## rating
	CRIT_CHANCE,  ## rating
	CRIT_DAMAGE,  ## percent extra damage on a critical hit
	STATUS_RESISTANCE,  ## rating
	SLOW_RESISTANCE,  ## rating
	MOVE_SPEED,
	SPELL_DAMAGE,  ## percent more damage from spells
	CAST_SPEED,  ## percent faster casting (the wind-up before a spell goes off)
	MANA_COST_REDUCTION,  ## rating
	PARRY,  ## rating: a parried attack misses, and gives combo (Rogue)
	BACKSTAB_DAMAGE,  ## percent more attack damage from behind
	COMBO_POWER,  ## percent more mana from hits and parries (Rogue)
	ATTACK_RANGE,  ## meters added to the attack's reach (Tamsin: Strength)
}

## StarCraft-style armor types; attack types deal bonus damage against some of them.
enum Armor { UNARMORED, LIGHT, MEDIUM, HEAVY }

const CORE: Array[Stat] = [Stat.STRENGTH, Stat.DEXTERITY, Stat.INTELLIGENCE, Stat.WILLPOWER]
const RATINGS: Array[Stat] = [Stat.EVASION, Stat.CRIT_CHANCE, Stat.STATUS_RESISTANCE, Stat.SLOW_RESISTANCE,
		Stat.MANA_COST_REDUCTION, Stat.PARRY]
const PERCENTS: Array[Stat] = [Stat.ATTACK_SPEED, Stat.CRIT_DAMAGE, Stat.SPELL_DAMAGE, Stat.CAST_SPEED,
		Stat.BACKSTAB_DAMAGE, Stat.COMBO_POWER]
## How the stats window lists the derived stats.
const DERIVED_ORDER: Array[Stat] = [Stat.MAX_HEALTH, Stat.HEALTH_REGEN, Stat.MAX_MANA, Stat.MANA_REGEN,
		Stat.MANA_COST_REDUCTION, Stat.COMBO_POWER, Stat.ATTACK_DAMAGE, Stat.ATTACK_SPEED, Stat.CRIT_CHANCE,
		Stat.CRIT_DAMAGE, Stat.BACKSTAB_DAMAGE, Stat.SPELL_DAMAGE, Stat.CAST_SPEED, Stat.ARMOR, Stat.EVASION, Stat.PARRY,
		Stat.STATUS_RESISTANCE, Stat.SLOW_RESISTANCE, Stat.MOVE_SPEED, Stat.ATTACK_RANGE]
const NAMES: Dictionary[Stat, String] = {
	Stat.STRENGTH: "Strength",
	Stat.DEXTERITY: "Dexterity",
	Stat.INTELLIGENCE: "Intelligence",
	Stat.WILLPOWER: "Willpower",
	Stat.MAX_HEALTH: "Health",
	Stat.HEALTH_REGEN: "Health regeneration",
	Stat.MAX_MANA: "Mana",
	Stat.MANA_REGEN: "Mana regeneration",
	Stat.ATTACK_DAMAGE: "Attack damage",
	Stat.ATTACK_SPEED: "Attack speed",
	Stat.ARMOR: "Armor",
	Stat.EVASION: "Evasion",
	Stat.CRIT_CHANCE: "Critical chance",
	Stat.CRIT_DAMAGE: "Critical damage",
	Stat.STATUS_RESISTANCE: "Status resistance",
	Stat.SLOW_RESISTANCE: "Slow resistance",
	Stat.MOVE_SPEED: "Move speed",
	Stat.SPELL_DAMAGE: "Spell damage",
	Stat.CAST_SPEED: "Cast speed",
	Stat.MANA_COST_REDUCTION: "Mana cost reduction",
	Stat.PARRY: "Parry",
	Stat.BACKSTAB_DAMAGE: "Backstab damage",
	Stat.COMBO_POWER: "Combo power",
	Stat.ATTACK_RANGE: "Attack range",
}
const ARMOR_NAMES: Dictionary[Armor, String] = {
	Armor.UNARMORED: "Unarmored",
	Armor.LIGHT: "Light",
	Armor.MEDIUM: "Medium",
	Armor.HEAVY: "Heavy",
}
## What one point of each core stat gives every hero.
const GENERAL_BONUS: Dictionary[Stat, Stat] = {
	Stat.STRENGTH: Stat.MAX_HEALTH,
	Stat.DEXTERITY: Stat.ATTACK_SPEED,
	Stat.INTELLIGENCE: Stat.MAX_MANA,
	Stat.WILLPOWER: Stat.HEALTH_REGEN,
}
const GENERAL_PER_POINT: Dictionary[Stat, float] = {
	Stat.STRENGTH: 25.0,  # Warcraft III: 25 health per Strength
	Stat.DEXTERITY: 1.0,  # DotaCraft: 1% attack speed per Agility
	Stat.INTELLIGENCE: 15.0,  # Warcraft III: 15 mana per Intelligence
	Stat.WILLPOWER: 0.05,  # Warcraft III's health regeneration per Strength
}
const BASE_CRIT_DAMAGE := 50.0  ## a critical hit deals +50% before any bonus
const MIN_DAMAGE := 0.5  ## armor never takes a hit below this (StarCraft)


static func is_core(stat: Stat) -> bool:
	return stat <= Stat.WILLPOWER


## What a stat's total does: the diminished percent for ratings, the total for the rest.
static func effective(stat: Stat, total: float) -> float:
	if stat in RATINGS and total > 0.0:
		return 100.0 * total / (100.0 + total)
	return total


## A stat's effective value as shown to the player: "21", "12.5%", "0.90/s".
static func format_value(stat: Stat, total: float) -> String:
	var value := effective(stat, total)
	if stat in RATINGS:
		return "%.1f%%" % value
	if stat in PERCENTS:
		return "%s%%" % _number(value)
	match stat:
		Stat.MAX_HEALTH, Stat.MAX_MANA:
			return str(roundi(value))
		Stat.HEALTH_REGEN, Stat.MANA_REGEN:
			return "%.2f/s" % value
		Stat.MOVE_SPEED:
			return "%.1f m/s" % value
		Stat.ATTACK_RANGE:
			return "+%.1f m" % value
	return _number(value)


## A bonus as an item line: "+3 Strength", "+15% Attack speed", "+20 Evasion rating".
static func format_bonus(stat: Stat, amount: float) -> String:
	if stat in RATINGS:
		return "%s %s rating" % [format_amount(stat, amount), NAMES[stat]]
	return "%s %s" % [format_amount(stat, amount), NAMES[stat]]


## Just the signed amount in the stat's unit: "+3", "+15%", "+0.05/s", "+1.0 m/s".
static func format_amount(stat: Stat, amount: float) -> String:
	var prefix := "+" if amount >= 0.0 else "-"
	var size := absf(amount)
	if stat in PERCENTS:
		return "%s%s%%" % [prefix, _number(size)]
	match stat:
		Stat.HEALTH_REGEN, Stat.MANA_REGEN:
			return "%s%s/s" % [prefix, String.num(size, 3 if size < 0.1 else 2)]
		Stat.MOVE_SPEED:
			return "%s%.1f m/s" % [prefix, size]
		Stat.ATTACK_RANGE:
			return "%s%.1f m" % [prefix, size]
	return "%s%s" % [prefix, _number(size)]


## 12 rather than 12.0, but 2.7 stays 2.7 and 0.02 stays 0.02.
static func _number(value: float) -> String:
	if is_equal_approx(value, roundf(value)):
		return str(roundi(value))
	return String.num(value, 1 if absf(value) >= 1.0 else 2)
