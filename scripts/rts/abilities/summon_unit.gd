extends AbilityDefinition

## DotaCraft archmage_summon_water_elemental (summon_water_elemental.lua): summons a
## controllable unit in front of the caster for `duration` seconds. Its health and
## damage come from the ability level, like human_water_elemental_1..3.

const UNIT_SCENE := preload("res://scenes/unit.tscn")
const SUMMON_DISTANCE := 200.0 / RTSCamera.NOH_UNITS_PER_METER
const FLASH := Color(0.4, 0.7, 1.0, 0.8)

@export var summon: UnitDefinition

var _per_level: Dictionary[int, UnitDefinition] = {}


func cast(spell: SpellCast) -> void:
	var caster := spell.caster
	var forward := Vector3(sin(caster.rotation.y), 0.0, cos(caster.rotation.y))
	var unit: Unit = UNIT_SCENE.instantiate()
	unit.definition = _definition_for(spell.level, spell)
	unit.team = caster.team
	unit.registry = spell.registry
	unit.lifetime = spell.value(&"duration")
	unit.position = caster.global_position + forward * SUMMON_DISTANCE
	unit.rotation.y = caster.rotation.y
	caster.get_parent().add_child(unit)
	SpellEffects.pillar(spell.registry, unit.global_position, FLASH, 0.8, 4.0, 0.6)


func _definition_for(level: int, spell: SpellCast) -> UnitDefinition:
	if not _per_level.has(level):
		var leveled: UnitDefinition = summon.duplicate()
		leveled.max_health = spell.value(&"hit_points")
		leveled.attack_damage = spell.value(&"damage")
		leveled.display_name = "%s (%d)" % [summon.display_name, level]
		_per_level[level] = leveled
	return _per_level[level]
