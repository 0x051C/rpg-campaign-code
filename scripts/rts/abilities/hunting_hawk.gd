extends AbilityDefinition

## Tamsin's ultimate, her hawk (STORY.md 6). Sent at a point, it flies there through every enemy in
## its path (within `radius` of the line), striking each for `strike_damage`; at level 3 it stays
## there, circling, for `scout_time` seconds: a summon that sees, and can be moved. And while she
## knows it, it comes for her when she's low: under a third of her health it heals her for
## `rescue_heal`, once every `rescue_cooldown` seconds.

const HAWK := preload("res://data/units/hawk.tres")
const UNIT_SCENE := preload("res://scenes/unit.tscn")
const COLOR := Color(0.95, 0.78, 0.45)
const LOW := 0.33
const RESCUE_META := &"hawk_rescue_at"


func cast(spell: SpellCast) -> void:
	var registry := spell.registry
	var to := spell.point
	strike(spell.caster, spell.caster.global_position, to, spell.value(&"strike_damage"))
	var scout := spell.value(&"scout_time")
	if scout > 0.0:
		var hawk: Unit = UNIT_SCENE.instantiate()
		hawk.definition = HAWK
		hawk.team = spell.caster.team
		hawk.registry = registry
		hawk.lifetime = scout
		hawk.position = Vector3(to.x, 0.0, to.z)
		spell.caster.get_parent().add_child(hawk)


func on_owner_damaged(unit: Unit, level: int, _source: int) -> void:
	var registry := unit.registry
	if not unit.is_alive() or registry.health_of(unit.handle) >= registry.max_health_of(unit.handle) * LOW:
		return
	if registry.now() < float(unit.get_meta(RESCUE_META, 0.0)):
		return
	unit.set_meta(RESCUE_META, registry.now() + value(&"rescue_cooldown", level))
	registry.heal(unit.handle, value(&"rescue_heal", level))
	SpellEffects.pillar(registry, unit.global_position, COLOR, 0.7, 4.0, 0.6)
	Sounds.play_at(&"news", unit.global_position)


## Its flight from `from` to `to`: every enemy of `caster` within `radius` of the line is struck for `damage`.
func strike(caster: Unit, from: Vector3, to: Vector3, damage: float) -> void:
	var registry := caster.registry
	var flat_from := Vector2(from.x, from.z)
	var flat_to := Vector2(to.x, to.z)
	var middle := (from + to) * 0.5
	for other in registry.query_radius(middle, from.distance_to(to) * 0.5 + radius):
		if not UnitRegistry.are_enemies(registry.team_of(other), caster.team):
			continue
		var at := registry.position_of(other)
		var flat := Vector2(at.x, at.z)
		if flat.distance_to(Geometry2D.get_closest_point_to_segment(flat, flat_from, flat_to)) <= radius:
			registry.apply_damage(other, damage, caster.handle, false)
			registry.flash(other, COLOR)
	# Its flight: a streak of small rings along the line, then a gust where it lands
	var steps := maxi(int(from.distance_to(to) / 2.0), 1)
	for i in steps + 1:
		SpellEffects.pulse(registry, Terrain.lift(from.lerp(to, float(i) / steps)), 1.0, COLOR, 0.25 + 0.03 * i)
	SpellEffects.pulse(registry, Terrain.lift(to), radius * 1.5, COLOR, 0.5)


## A computer Tamsin (Risen, the arena) sends it through the thickest line of enemies in reach.
func ai_target(unit: Unit, _slot: int) -> Dictionary:
	var foes := AbilityDefinition.ai_enemies(unit, unit.global_position, cast_range)
	if foes.size() < 3:
		return {}
	return {"point": unit.registry.position_of(foes[foes.size() / 2])}
