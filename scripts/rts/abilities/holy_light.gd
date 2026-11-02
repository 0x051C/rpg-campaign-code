extends AbilityDefinition

## Holy Light as an area spell (STORY.md 6, Ser Aldith's kit), NoH Jeraziah's Inner Light
## (heroes/jereziah/ability_01: heal the targeted ally, sear the enemies around it): a living
## friendly unit, the caster too, is healed for `heal_amount`, and every enemy within `radius`
## of it takes `sear_damage`, the undead twice that. Not an undead ally.

const HOLY := Color(1.0, 0.85, 0.35, 0.9)
const UNDEAD_FACTOR := 2.0


func check_target(spell: SpellCast, target: int) -> String:
	var registry := spell.registry
	if not registry.is_alive(target):
		return "Must target a unit"
	if registry.team_of(target) != spell.caster.team:
		return "Must target a friendly unit"
	if registry.definition_of(target).undead:
		return "Can't target undead allies"
	return ""


func cast(spell: SpellCast) -> void:
	var registry := spell.registry
	var at := registry.position_of(spell.target)
	if registry.health_of(spell.target) < registry.max_health_of(spell.target):
		registry.heal(spell.target, spell.value(&"heal_amount"))
	var sear := spell.value(&"sear_damage")
	for other in registry.query_radius(at, radius):
		if UnitRegistry.are_enemies(registry.team_of(other), spell.caster.team):
			var undead := registry.definition_of(other).undead
			registry.apply_damage(other, sear * (UNDEAD_FACTOR if undead else 1.0), spell.caster.handle, false)
			registry.flash(other, HOLY)
	SpellEffects.pillar(registry, at, HOLY)
	SpellEffects.pulse(registry, at, radius, HOLY)


## A computer hero (Risen Aldith, the arena) lights up a hurt ally standing among enemies, or
## itself when the enemies crowd it.
func ai_target(unit: Unit, _slot: int) -> Dictionary:
	var registry := unit.registry
	var best := UnitRegistry.NONE
	var best_score := 0.0
	for other in registry.query_radius(unit.global_position, cast_range):
		if registry.team_of(other) != unit.team or registry.definition_of(other).undead:
			continue
		var enemies := AbilityDefinition.ai_enemies(unit, registry.position_of(other), radius).size()
		var missing := 1.0 - registry.health_of(other) / maxf(registry.max_health_of(other), 1.0)
		var score := enemies * 1.0 + missing * 4.0
		if score > best_score:
			best_score = score
			best = other
	return {"target": best} if best != UnitRegistry.NONE and best_score >= 2.5 else {}


## The area around the hovered friend, and what the light would do there.
func draw_targeting(indicator: TargetingIndicator, spell: SpellCast) -> void:
	super(indicator, spell)
	var target := indicator.hover
	if target == UnitRegistry.NONE:
		return
	var error := check_target(spell, target)
	if not error.is_empty():
		indicator.unit_label(target, error, TargetingIndicator.INVALID_COLOR, 14)
		return
	indicator.circle(spell.registry.position_of(target), radius, HOLY)
	indicator.unit_label(target, "+%d" % spell.value(&"heal_amount"), TargetingIndicator.VALID_COLOR, 20)
