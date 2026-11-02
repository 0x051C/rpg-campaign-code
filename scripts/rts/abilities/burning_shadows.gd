extends AbilityDefinition

## NoH Fayde, Ability_Fade2 "Burning Shadows" (game/heroes/fade/ability_02): a wave of
## darkness rolls from the caster toward the target point, {length} m long and `radius`
## wide on each side. Every enemy it reaches is stunned for {stun} seconds and bleeds for
## {bleed_damage} magic damage a second over {bleed_duration} seconds. (In NoH it only hit
## enemy heroes; here it hits every enemy unit.)

const SHADOW := Color(0.35, 0.1, 0.3, 0.85)
const STEPS := 10


func cast(spell: SpellCast) -> void:
	var registry := spell.registry
	var origin := spell.caster.global_position
	var direction := spell.point - origin
	direction.y = 0.0
	direction = direction.normalized() if direction.length_squared() > 0.0001 else \
			Vector3(sin(spell.caster.rotation.y), 0.0, cos(spell.caster.rotation.y))
	var length := spell.value(&"length")
	var hit := {}  # each unit once, like maximpactspertarget="1"
	for step in STEPS:
		var distance := length * (step + 1) / STEPS
		var at := origin + direction * distance
		registry.get_tree().create_timer(distance / spell.value(&"speed")).timeout.connect(
				_roll.bind(spell, at, hit))


## The wave front reaches `at`.
func _roll(spell: SpellCast, at: Vector3, hit: Dictionary) -> void:
	var registry := spell.registry
	if not is_instance_valid(registry) or not is_instance_valid(spell.caster):
		return
	SpellEffects.pulse(registry, at, radius, SHADOW, 0.35)
	var team := spell.caster.team
	for victim in registry.query_radius(at, radius):
		if hit.has(victim) or not UnitRegistry.are_enemies(registry.team_of(victim), team):
			continue
		hit[victim] = true
		registry.add_effect(victim, &"stunned", spell.value(&"stun"), spell.caster.handle, {"stun": true})
		registry.add_effect(victim, &"bleeding", spell.value(&"bleed_duration"), spell.caster.handle,
				{"dps": spell.value(&"bleed_damage")})
		registry.flash(victim, SHADOW)


func draw_targeting(indicator: TargetingIndicator, spell: SpellCast) -> void:
	super(indicator, spell)
	var origin := spell.caster.global_position
	var direction := indicator.cursor - origin
	direction.y = 0.0
	if direction.length_squared() < 0.0001:
		return
	direction = direction.normalized()
	var side := Vector3(direction.z, 0.0, -direction.x) * radius
	var tip := origin + direction * spell.value(&"length")
	indicator.line(origin + side, tip + side)
	indicator.line(origin - side, tip - side)
	indicator.line(tip + side, tip - side)
