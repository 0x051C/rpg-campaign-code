class_name AbilityDefinition
extends Resource

## A hero spell: DotaCraft's ability key values (scripts/npc/abilities/heroes) with
## noh's tool action types (TOOL_ACTION_*) deciding how the commander targets it.
## Per-level numbers are arrays indexed by level - 1. Subclasses implement the effect.

enum Action {
	PASSIVE,  ## TOOL_ACTION_PASSIVE
	NO_TARGET,  ## TOOL_ACTION_NO_TARGET
	TARGET_UNIT,  ## TOOL_ACTION_TARGET_ENTITY
	TARGET_POINT,  ## TOOL_ACTION_TARGET_POSITION
	TARGET_UNIT_OR_POINT,  ## TOOL_ACTION_TARGET_DUAL
	ATTACK,  ## TOOL_ACTION_ATTACK: an attack modifier that can autocast
}
enum Targets { ENEMIES, ALLIES, ANY }


@export var display_name := "Ability"
## Shown in the tooltip; {key} is replaced by values[key] at the shown level.
@export_multiline var description := ""
@export var icon_glyph := "?"
@export var icon_color := Color.GRAY
## A picture for the spell button; the glyph on icon_color is drawn when there's none.
@export var icon: Texture2D
@export var action := Action.NO_TARGET
@export var targets := Targets.ENEMIES
@export var ultimate := false
@export var max_level := 3
@export var mana_cost := PackedFloat32Array([0.0])
@export var cooldown := PackedFloat32Array([0.0])
@export var cast_range := 0.0  ## 0 means no range limit
@export var radius := 0.0  ## area of effect, drawn while targeting
@export var cast_point := 0.3
@export var channel_time := PackedFloat32Array()
@export var values: Dictionary[StringName, PackedFloat32Array] = {}
## Casting it ends the caster's stealth (off for Vanish itself).
@export var breaks_stealth := true
## Known from level 1 without spending a skill point (Maren's Call Brook).
@export var innate := false
## Its element: the impact sound when it goes off (Sounds), later resistances.
@export_enum("none", "fire", "ice", "lightning", "water") var element: String = "none"


## For a computer-controlled hero (HeroBrain): where to cast this now, {"target": handle}
## or {"point": position}, or {} to hold it. Abilities without a rule are never cast by it.
func ai_target(_unit: Unit, _slot: int) -> Dictionary:
	return {}


## Enemies of `unit` that its team sees within `range_meters` of `center`, nearest first.
static func ai_enemies(unit: Unit, center: Vector3, range_meters: float) -> Array[int]:
	var registry := unit.registry
	var found: Array[int] = []
	for other in registry.query_radius(center, range_meters):
		if UnitRegistry.are_enemies(registry.team_of(other), unit.team) and registry.can_see(unit.team, other):
			found.append(other)
	found.sort_custom(func(a: int, b: int) -> bool:
		return registry.position_of(a).distance_squared_to(center) < registry.position_of(b).distance_squared_to(center))
	return found


## Its name in per-character tables (CharacterModel clips, VoiceSet lines): the file name,
## "paladin_holy_light" for data/abilities/paladin_holy_light.tres.
func id() -> StringName:
	return StringName(resource_path.get_file().get_basename())


func value(key: StringName, level: int) -> float:
	return per_level(values.get(key, PackedFloat32Array()), level)


func mana_cost_at(level: int) -> float:
	return per_level(mana_cost, level)


func cooldown_at(level: int) -> float:
	return per_level(cooldown, level)


func channel_time_at(level: int) -> float:
	return per_level(channel_time, level)


## Hero level needed to learn `ability_level` (Warcraft III: 1/3/5, ultimates at 6).
func required_hero_level(ability_level: int) -> int:
	return 6 if ultimate else 1 + (ability_level - 1) * 2


func is_passive() -> bool:
	return action == Action.PASSIVE


func describe(level: int) -> String:
	var text := description
	for key in values:
		text = text.replace("{%s}" % key, format_number(value(key, maxi(level, 1))))
	return text


## 400 rather than 400.0, but 0.75 stays 0.75.
static func format_number(number: float) -> String:
	if is_equal_approx(number, roundf(number)):
		return str(roundi(number))
	return String.num(number, 2)


## noh CastFilterResultTarget: an empty string when `target` is fine, else the error.
func check_target(spell: SpellCast, target: int) -> String:
	var registry := spell.registry
	if not registry.is_alive(target):
		return "Must target a unit"
	if registry.is_neutral(target):
		return "Can't target neutral units"
	var enemy := UnitRegistry.are_enemies(registry.team_of(target), spell.caster.team)
	if targets == Targets.ENEMIES and not enemy:
		return "Must target an enemy"
	if targets == Targets.ALLIES and enemy:
		return "Must target an ally"
	return ""


## What the player sees while aiming this spell. By default: the cast range around
## the caster, the area of effect under the cursor, and for unit-targeted spells a
## green or red ring on the hovered unit. Override to draw something else; the
## overlay calls this every frame of the targeting state with `spell.target` set to
## the hovered unit and `spell.point` to the ground under the cursor.
func draw_targeting(indicator: TargetingIndicator, spell: SpellCast) -> void:
	if cast_range > 0.0:
		indicator.circle(spell.caster.global_position, cast_range + spell.caster.definition.radius, TargetingIndicator.RANGE_COLOR, 1.5)
	var unit_targeted := action == Action.TARGET_UNIT or action == Action.ATTACK or action == Action.TARGET_UNIT_OR_POINT
	if radius > 0.0 and action != Action.TARGET_UNIT and action != Action.ATTACK:
		indicator.circle(indicator.cursor, radius)
	if unit_targeted and indicator.hover != UnitRegistry.NONE:
		var valid := check_target(spell, indicator.hover).is_empty()
		indicator.unit_ring(indicator.hover, TargetingIndicator.VALID_COLOR if valid else TargetingIndicator.INVALID_COLOR)


## Its owner cast `cast_ability` (any spell, this one too), knowing this at `level`: passives that
## answer every spell (Seeking Arrows).
func on_owner_cast(_unit: Unit, _level: int, _cast_ability: AbilityDefinition) -> void:
	pass


## Its owner was hurt by `source`, knowing this at `level` (Tamsin's hawk comes when she's low).
func on_owner_damaged(_unit: Unit, _level: int, _source: int) -> void:
	pass


## Its owner was placed on a map (a fresh start, or arriving with the party), knowing this
## ability at `level`: one that keeps something at its side sets it up (CallCompanion).
func on_owner_placed(_unit: Unit, _level: int) -> void:
	pass


## The effect at the cast point.
func cast(_spell: SpellCast) -> void:
	pass


## Called every tick (Simulation) while channeling.
func channel(_spell: SpellCast, _delta: float) -> void:
	pass


## Called when the channel runs out or gets interrupted by a new order.
func end_channel(_spell: SpellCast, _interrupted: bool) -> void:
	pass


static func per_level(array: PackedFloat32Array, level: int) -> float:
	if array.is_empty():
		return 0.0
	return array[clampi(level - 1, 0, array.size() - 1)]
