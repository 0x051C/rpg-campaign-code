class_name SpellCast
extends RefCounted

## One use of an ability, alive from the cast point until its channel ends.

var ability: AbilityDefinition
var level := 1
var caster: Unit
var registry: UnitRegistry
var target := UnitRegistry.NONE
var point := Vector3.ZERO
var elapsed := 0.0  ## time spent channeling
var timer := 0.0  ## free for the ability, e.g. time until the next wave
var mana_spent := 0.0  ## what the cast cost, after mana cost reduction
var effects: Array[Node] = []  ## visuals freed when the cast ends
var data: Dictionary = {}  ## free for the ability: what it keeps between ticks (Swift Slashes' marks)


func value(key: StringName) -> float:
	return ability.value(key, level)


func free_effects() -> void:
	for effect in effects:
		if is_instance_valid(effect):
			effect.queue_free()
	effects.clear()
