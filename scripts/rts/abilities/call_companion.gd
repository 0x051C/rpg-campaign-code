extends AbilityDefinition

## Maren's Brook, Rexxar's Misha from Warcraft III's campaign: a summon bound to its caster,
## with no timed life. It comes along to every map (called anew when the party arrives), and
## when it dies, casting this calls it back. Cast while it lives, it returns to the caster's
## side, a little healed. Its health, its damage and the mana its attacks give the caster
## (through a ChillingAttack) come from this ability's level, at the time it's called.

const UNIT_SCENE := preload("res://scenes/unit.tscn")
const SUMMON_DISTANCE := 2.0
const RECALL_HEAL := 0.25  ## share of its health a recall restores
const FLASH := Color(0.4, 0.7, 1.0, 0.8)

@export var companion: UnitDefinition

var _per_level: Dictionary[int, UnitDefinition] = {}


func cast(spell: SpellCast) -> void:
	var caster := spell.caster
	var existing := companion_of(caster)
	if existing == null:
		_call(caster, spell.level)
		return
	existing.teleport(_beside(caster))
	spell.registry.heal(existing.handle, spell.registry.max_health_of(existing.handle) * RECALL_HEAL)
	SpellEffects.pillar(spell.registry, existing.global_position, FLASH, 0.6, 3.0, 0.4)


func on_owner_placed(unit: Unit, level: int) -> void:
	if companion_of(unit) == null:
		_call(unit, level)


## The caster's living companion from this ability, or null.
func companion_of(caster: Unit) -> Unit:
	for unit in caster.registry.unit_nodes():
		if unit.bound and unit.companion_of == resource_path and unit.summoner == caster and unit.is_alive():
			return unit
	return null


func _call(caster: Unit, level: int) -> void:
	var unit: Unit = UNIT_SCENE.instantiate()
	unit.definition = _definition_for(level)
	unit.team = caster.team
	unit.player_id = caster.player_id
	unit.registry = caster.registry
	unit.bound = true
	unit.summoner = caster
	unit.companion_of = resource_path
	unit.position = _beside(caster)
	unit.rotation.y = caster.rotation.y
	caster.get_parent().add_child(unit)
	SpellEffects.pillar(caster.registry, unit.global_position, FLASH, 0.8, 4.0, 0.6)


## A little in front of the caster.
func _beside(caster: Unit) -> Vector3:
	var forward := Vector3(sin(caster.rotation.y), 0.0, cos(caster.rotation.y))
	return caster.global_position + forward * SUMMON_DISTANCE


func _definition_for(level: int) -> UnitDefinition:
	if not _per_level.has(level):
		var leveled: UnitDefinition = companion.duplicate()
		leveled.max_health = value(&"hit_points", level)
		leveled.attack_damage = value(&"damage", level)
		if companion.attack_effect is ChillingAttack:
			var chill: ChillingAttack = companion.attack_effect.duplicate()
			chill.summoner_mana = value(&"mana_per_hit", level)
			leveled.attack_effect = chill
		_per_level[level] = leveled
	return _per_level[level]
