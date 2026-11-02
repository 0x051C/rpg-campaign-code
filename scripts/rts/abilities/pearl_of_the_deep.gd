extends AbilityDefinition

## Maren's ultimate (DIRECTION.md 6; Keeper of the Light's Will-O-Wisp, blessed by the sea): a
## pearl rises where she points, for `duration` seconds. While it shines (`shine` seconds, then
## `rest` seconds dark, over and over) every enemy within `radius` is entranced: it can't move,
## attack or cast, and drifts in towards the pearl; each time it lights up, a wave breaks over them
## for `wave_damage`. Allies in its light regain `mana_per_second` mana a second.

const PEARL := preload("res://scripts/rts/abilities/sea_pearl.gd")


func cast(spell: SpellCast) -> void:
	var pearl: Node3D = PEARL.new()
	pearl.caster = spell.caster
	pearl.registry = spell.registry
	pearl.radius = radius
	pearl.duration = spell.value(&"duration")
	pearl.shine = spell.value(&"shine")
	pearl.rest = spell.value(&"rest")
	pearl.wave_damage = spell.value(&"wave_damage")
	pearl.mana_per_second = spell.value(&"mana_per_second")
	pearl.position = Terrain.lift(Vector3(spell.point.x, 0.0, spell.point.z))  # before it enters: its first wave breaks there
	spell.registry.get_parent().add_child(pearl)
	spell.data["pearl"] = pearl  # for item powers that change it (Tidecaller's Pearl)


## A computer Maren would drop it on the thickest crowd in reach.
func ai_target(unit: Unit, _slot: int) -> Dictionary:
	var foes := AbilityDefinition.ai_enemies(unit, unit.global_position, cast_range)
	if foes.size() < 4:
		return {}
	return {"point": unit.registry.position_of(foes[foes.size() / 2])}
