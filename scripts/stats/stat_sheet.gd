class_name StatSheet
extends RefCounted

## A unit's stats worked out from its definition, level and worn items, remembering where
## every part came from so tooltips can break a total down. Units without core stats
## (summons) only get their definition's numbers and their items.

var totals := PackedFloat32Array()
var sources: Array[Array] = []  ## per stat: [label, amount] pairs, in the order added


func _init() -> void:
	totals.resize(Stats.Stat.size())
	for i in Stats.Stat.size():
		sources.append([])


## `extras`: temporary bonuses (buffs) as [label, stat, amount] entries.
static func build(definition: UnitDefinition, level: int, worn: Array[ItemDefinition], extras: Array = []) -> StatSheet:
	var sheet := StatSheet.new()
	# Core stats: the class at this level, then items
	if definition.base_stats.size() == Stats.CORE.size():
		for i in Stats.CORE.size():
			var gain := definition.stat_gains[i] if i < definition.stat_gains.size() else 0.0
			sheet.add(Stats.CORE[i], definition.base_stats[i] + gain * (level - 1), "%s, level %d" % [definition.display_name, level])
	for item in worn:
		if item != null:
			for stat: Stats.Stat in item.bonuses:
				if Stats.is_core(stat):
					sheet.add(stat, item.bonuses[stat], item.display_name)

	sheet.add(Stats.Stat.MAX_HEALTH, definition.max_health, "Base")
	sheet.add(Stats.Stat.MAX_MANA, definition.max_mana, "Base")
	sheet.add(Stats.Stat.MANA_REGEN, definition.mana_regen, "Base")
	sheet.add(Stats.Stat.ARMOR, definition.armor, "Base")
	sheet.add(Stats.Stat.ATTACK_DAMAGE, definition.attack_damage, "Base")
	sheet.add(Stats.Stat.MOVE_SPEED, definition.move_speed, "Base")
	sheet.add(Stats.Stat.CRIT_DAMAGE, Stats.BASE_CRIT_DAMAGE, "Base")

	# What every hero gets from its core stats
	for core in Stats.CORE:
		sheet.add(Stats.GENERAL_BONUS[core], sheet.totals[core] * Stats.GENERAL_PER_POINT[core], Stats.NAMES[core])

	# Passives: each turns a core stat into a bonus (the main stat into attack damage, ...)
	for passive in definition.all_passives():
		for stat: Stats.Stat in passive.bonuses:
			sheet.add(stat, passive.bonuses[stat], passive.display_name)
		for conversion in passive.conversions:
			sheet.add(conversion.to, sheet.totals[conversion.from] * conversion.per_point,
					"%s (%s)" % [passive.display_name, Stats.NAMES[conversion.from]])

	for item in worn:
		if item != null:
			for stat: Stats.Stat in item.bonuses:
				if not Stats.is_core(stat):
					sheet.add(stat, item.bonuses[stat], item.display_name)
	for extra: Array in extras:
		sheet.add(extra[1], extra[2], extra[0])
	return sheet


func add(stat: Stats.Stat, amount: float, label: String) -> void:
	if is_zero_approx(amount):
		return
	totals[stat] += amount
	sources[stat].append([label, amount])


func value(stat: Stats.Stat) -> float:
	return totals[stat]


## The total as it works in combat (chances diminished).
func effective(stat: Stats.Stat) -> float:
	return Stats.effective(stat, totals[stat])
