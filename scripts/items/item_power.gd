class_name ItemPower
extends Resource

## What a legendary item does besides its stats (DIRECTION.md 1; Diablo 3's orange items): the
## hero wearing it gets these hooks called (Unit). Subclasses in scripts/items/powers override the
## ones they need; `description` is shown in orange on the item, with {key} filled from `values`.

@export_multiline var description := ""
@export var values: Dictionary[StringName, float] = {}


## An attack of `unit` landed on `victim` for `damage`.
func on_attack_landed(_unit: Unit, _victim: int, _damage: float) -> void:
	pass


## `unit` cast `ability` (`spell`: where, at what).
func on_cast(_unit: Unit, _ability: AbilityDefinition, _spell: SpellCast) -> void:
	pass


## `unit` was hurt by `source`.
func on_damaged(_unit: Unit, _source: int) -> void:
	pass


## `unit` landed the killing blow on `victim`, which fell at `at`.
func on_kill(_unit: Unit, _victim: int, _at: Vector3) -> void:
	pass


func value(key: StringName) -> float:
	return values.get(key, 0.0)


## Its description with the numbers in.
func describe() -> String:
	var text := description
	for key in values:
		text = text.replace("{%s}" % key, AbilityDefinition.format_number(values[key]))
	return text


## A per-unit timer for powers with a cooldown: true (and restarts it) when it's ready.
static func cooldown_ready(unit: Unit, key: StringName, cooldown: float) -> bool:
	var now := unit.registry.now()
	if now < float(unit.get_meta(key, -1.0)):
		return false
	unit.set_meta(key, now + cooldown)
	return true
