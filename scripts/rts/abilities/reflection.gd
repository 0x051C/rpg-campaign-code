extends AbilityDefinition

## NoH Fayde, Ability_Fade4 "Reflection" (game/heroes/fade/ability_04): leaves an illusion
## where the caster stands, which fights with the caster's base damage but takes
## {illusion_damage_taken}% damage, and turns the caster invisible for {duration} seconds,
## {move_speed}% faster, disjointing. Attacking doesn't reveal: each of the next {charges}
## landed attacks applies Shadow Cripple ({cripple_slow}% slow, {cripple_damage} magic damage
## a second per stack, for {cripple_duration} seconds). Casting a spell ends the stealth, so does
## running out of charges.
##
## Its area (DIRECTION.md 6, your call: Templar Assassin's Psi Blades, split): for its whole
## duration the illusion fights beside her, and both their attacks pass through their victims along
## {lines} blades (one straight on at level 1; two, then three, fanned out), {split_length} m long,
## for {split_share}% of the blow.

const UNIT_SCENE := preload("res://scenes/unit.tscn")
const SHADOW := Color(0.35, 0.15, 0.4, 0.8)

## Hero definition path -> its illusion. Keyed by path: the hero lists this ability, so
## holding the hero itself would be a reference cycle.
var _illusions: Dictionary[String, UnitDefinition] = {}


func cast(spell: SpellCast) -> void:
	var caster := spell.caster
	var duration := spell.value(&"duration")
	var illusion: Unit = UNIT_SCENE.instantiate()
	illusion.definition = _illusion_of(caster.definition)
	illusion.team = caster.team
	illusion.registry = spell.registry
	illusion.lifetime = duration
	illusion.level = caster.level
	illusion.equipment = caster.equipment.duplicate()
	illusion.damage_taken = spell.value(&"illusion_damage_taken") / 100.0
	illusion.position = caster.global_position
	illusion.rotation.y = caster.rotation.y
	caster.get_parent().add_child(illusion)
	illusion.order_hold(Unit.Queue.NONE)  # NoH fixedposition: it stays where she stood
	var lines := roundi(spell.value(&"lines"))
	var share := spell.value(&"split_share") / 100.0
	var length := spell.value(&"split_length")
	caster.split_attacks(lines, share, length, duration)
	illusion.split_attacks(lines, share, length, duration)

	caster.disjoint()
	var bonus := caster.stats.value(Stats.Stat.MOVE_SPEED) * spell.value(&"move_speed") / 100.0
	caster.add_buff(&"reflection", display_name, icon_glyph, icon_color,
			"+%d%% move speed while hidden." % roundi(spell.value(&"move_speed")), duration, {Stats.Stat.MOVE_SPEED: bonus})
	caster.reflect(self, duration, roundi(spell.value(&"charges")), {
		"slow": spell.value(&"cripple_slow") / 100.0,
		"dps": spell.value(&"cripple_damage"),
		"time": spell.value(&"cripple_duration"),
	}, illusion)
	SpellEffects.pulse(spell.registry, caster.global_position, 1.6, SHADOW, 0.5)


## The hero's definition without its abilities: an illusion only fights.
func _illusion_of(hero: UnitDefinition) -> UnitDefinition:
	if not _illusions.has(hero.resource_path):
		var copy: UnitDefinition = hero.duplicate()
		copy.abilities = []
		_illusions[hero.resource_path] = copy
	return _illusions[hero.resource_path]
