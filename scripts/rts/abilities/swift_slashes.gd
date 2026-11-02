extends AbilityDefinition

## Rogue ultimate (after NoH's Swiftblade): the Rogue blinks between enemies around the
## target, striking {strikes} times over the channel. Each strike is a normal attack for
## {damage_percent}% of the Rogue's attack damage (armor, evasion and parries apply) and
## builds combo like any hit.
##
## Its area (DIRECTION.md 6): every enemy struck carries a shadow mark, and {mark_delay} seconds after
## the last slash each mark bursts for {mark_share}% of what the slashes did to it, onto every enemy
## within {mark_radius} m. A pack she dances through goes off like firecrackers.

const SHADOW := Color(0.45, 0.25, 0.6, 0.9)

const EDGE := Color(0.75, 0.85, 1.0, 0.9)
const STRIKE_DISTANCE := 0.9


func cast(spell: SpellCast) -> void:
	spell.timer = 0.0


func channel(spell: SpellCast, delta: float) -> void:
	spell.timer -= delta
	if spell.timer > 0.0:
		return
	spell.timer = channel_time_at(spell.level) / spell.value(&"strikes")
	var caster := spell.caster
	var registry := spell.registry
	var victim := _next_victim(spell)
	if victim == UnitRegistry.NONE:
		return
	var at := registry.position_of(victim)
	var side := Vector3.FORWARD.rotated(Vector3.UP, randf() * TAU) * (STRIKE_DISTANCE + registry.radius_of(victim))
	caster.blink_to(at + side)
	caster.look_at(Vector3(at.x, caster.global_position.y, at.z), Vector3.UP, true)
	caster.play_strike(self, spell.timer)
	var damage := registry.attack_damage(caster.handle, caster.attack_damage()) * spell.value(&"damage_percent") / 100.0
	if registry.deliver_attack(caster.handle, victim, damage, caster.definition):
		caster.gain_combo(caster.definition.mana_per_hit)
		var marks: Dictionary = spell.data.get_or_add("marks", {})
		var mark: Dictionary = marks.get_or_add(victim, {"damage": 0.0, "at": at})
		mark.damage += damage
		mark.at = at
	SpellEffects.pulse(registry, at, 0.8, EDGE, 0.25)


## The slashes are over: the marks burst a moment later, where their bearers stand (or fell).
func end_channel(spell: SpellCast, _interrupted: bool) -> void:
	var marks: Dictionary = spell.data.get("marks", {})
	if marks.is_empty():
		return
	var registry := spell.registry
	var caster := spell.caster
	var share := spell.value(&"mark_share") / 100.0
	var reach := spell.value(&"mark_radius")
	registry.get_tree().create_timer(spell.value(&"mark_delay"), false).timeout.connect(func() -> void:
		if not is_instance_valid(registry) or not is_instance_valid(caster):
			return
		for victim: int in marks:
			var mark: Dictionary = marks[victim]
			var at: Vector3 = registry.position_of(victim) if registry.is_alive(victim) else mark.at
			SpellEffects.pulse(registry, Terrain.lift(at), reach, SHADOW, 0.35)
			for other in registry.query_radius(at, reach):
				if UnitRegistry.are_enemies(registry.team_of(other), caster.team):
					registry.apply_damage(other, float(mark.damage) * share, caster.handle, false)
		Sounds.play_at(&"lightning", caster.global_position))


## The target while it lives, else a random visible enemy near where it stood.
func _next_victim(spell: SpellCast) -> int:
	var registry := spell.registry
	var team := spell.caster.team
	if registry.is_alive(spell.target) and registry.can_see(team, spell.target) and randf() < 0.5:
		return spell.target
	if registry.is_alive(spell.target):
		spell.point = registry.position_of(spell.target)
	var choices: Array[int] = []
	for other in registry.query_radius(spell.point, radius):
		if UnitRegistry.are_enemies(registry.team_of(other), team) and registry.can_see(team, other):
			choices.append(other)
	return choices.pick_random() if not choices.is_empty() else UnitRegistry.NONE
