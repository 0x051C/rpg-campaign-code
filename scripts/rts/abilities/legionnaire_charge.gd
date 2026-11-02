extends AbilityDefinition

## NoH Legionnaire, Ability_Legionnaire2 (game/heroes/legionnaire/ability_02; the string
## tables call an older version "Terrify"): the caster charges the target at noh's top speed,
## through units, and on reaching it strikes with +{damage_bonus}% base damage. The blow
## cleaves a {cone_angle}° cone in front: everyone in it takes an attack's damage and is
## Terrified for {terrify_duration} seconds, dealing half damage.

const CHARGE_SPEED := 522.0 / RTSCamera.NOH_UNITS_PER_METER  ## noh's movement speed cap
const REACH := 100.0 / RTSCamera.NOH_UNITS_PER_METER  ## Order_Legionnaire_Ability2 triggerrange
const MAX_TIME := 5.0  ## State_Legionnaire_Ability2_Self duration
const CONE_RADIUS := 240.0 / RTSCamera.NOH_UNITS_PER_METER
const RAGE := Color(0.9, 0.35, 0.1, 0.85)
const AI_MIN_DISTANCE := 4.0  ## the computer doesn't charge what it could just walk to


func cast(spell: SpellCast) -> void:
	spell.caster.charge(self, spell.target, CHARGE_SPEED, REACH, MAX_TIME, _strike.bind(spell.caster, spell.level))


func _strike(target: int, caster: Unit, level: int) -> void:
	if not is_instance_valid(caster) or not caster.is_alive():
		return
	var registry := caster.registry
	var damage := registry.attack_damage(caster.handle, caster.attack_damage())
	registry.deliver_attack(caster.handle, target, damage * (1.0 + value(&"damage_bonus", level) / 100.0), caster.definition)
	var facing := registry.position_of(target) - caster.global_position
	var half_angle := deg_to_rad(value(&"cone_angle", level)) * 0.5
	for victim in registry.query_radius(caster.global_position, CONE_RADIUS):
		if not UnitRegistry.are_enemies(registry.team_of(victim), caster.team):
			continue
		var to := registry.position_of(victim) - caster.global_position
		if victim != target and Vector2(to.x, to.z).angle_to(Vector2(facing.x, facing.z)) > half_angle:
			continue
		if victim != target:
			registry.apply_damage(victim, damage, caster.handle, true, false)  # the cleave
		registry.add_effect(victim, &"terrified", value(&"terrify_duration", level), caster.handle,
				{"damage_dealt": 1.0 - value(&"terrify_damage_reduction", level) / 100.0})
		registry.flash(victim, RAGE)
	caster.play_ability_clip(self, "_attack")
	SpellEffects.pulse(registry, registry.position_of(target), 1.5, RAGE, 0.4)


## Charges heroes first, then a pack of creeps it can't simply walk to.
func ai_target(unit: Unit, _slot: int) -> Dictionary:
	var registry := unit.registry
	var best := UnitRegistry.NONE
	for enemy in ai_enemies(unit, unit.global_position, cast_range):
		if registry.edge_distance(unit.handle, enemy) < AI_MIN_DISTANCE:
			continue
		if registry.unit_of(enemy) != null:
			return {"target": enemy}
		if best == UnitRegistry.NONE and ai_enemies(unit, registry.position_of(enemy), CONE_RADIUS).size() >= 3:
			best = enemy
	return {"target": best} if best != UnitRegistry.NONE else {}
