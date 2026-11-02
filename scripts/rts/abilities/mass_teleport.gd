extends AbilityDefinition

## DotaCraft archmage_mass_teleport (vscripts/heroes/archmage/mass_teleport.lua):
## after channeling, the caster and up to max_units_teleported of the player's units
## around it appear next to a friendly unit. Cast on a point, it picks the friendly
## unit closest to that point.

const TELEPORT := Color(0.45, 0.6, 1.0, 0.8)
const GRID_SPACING := 1.6


func check_target(spell: SpellCast, target: int) -> String:
	var error := super(spell, target)
	if error.is_empty() and target == spell.caster.handle:
		return "Can't target self"
	return error


func cast(spell: SpellCast) -> void:
	var registry := spell.registry
	if not registry.is_alive(spell.target):
		spell.target = _closest_friend(spell)
	if spell.target != UnitRegistry.NONE:
		SpellEffects.pulse(registry, registry.position_of(spell.target), radius * 0.4, TELEPORT, 1.0)
	SpellEffects.pulse(registry, spell.caster.global_position, radius, TELEPORT, 1.0)


func end_channel(spell: SpellCast, interrupted: bool) -> void:
	var registry := spell.registry
	if interrupted or not registry.is_alive(spell.target):
		return
	var travellers: Array[Unit] = [spell.caster]
	for handle in registry.query_radius(spell.caster.global_position, radius):
		var unit := registry.unit_of(handle)
		if unit != null and unit != spell.caster and unit.team == spell.caster.team and travellers.size() <= int(spell.value(&"max_units_teleported")):
			travellers.append(unit)
	var destination := registry.position_of(spell.target)
	var columns := ceili(sqrt(travellers.size()))
	for i in travellers.size():
		var offset := Vector3((i % columns - (columns - 1) * 0.5) * GRID_SPACING, 0.0, (floorf(float(i) / columns) + 1.0) * GRID_SPACING)
		travellers[i].teleport(destination + offset)
		SpellEffects.pillar(registry, destination + offset, TELEPORT, 0.6, 4.0, 0.6)


func _closest_friend(spell: SpellCast) -> int:
	var registry := spell.registry
	var best := UnitRegistry.NONE
	var best_distance := INF
	for handle in registry.query_radius(spell.point, 1000.0):
		if handle == spell.caster.handle or registry.team_of(handle) != spell.caster.team:
			continue
		var distance := registry.position_of(handle).distance_to(spell.point)
		if distance < best_distance:
			best_distance = distance
			best = handle
	return best


## Rings the units that would come along and links the caster to the destination.
func draw_targeting(indicator: TargetingIndicator, spell: SpellCast) -> void:
	var registry := spell.registry
	indicator.circle(spell.caster.global_position, radius, TargetingIndicator.RANGE_COLOR, 1.5)
	for handle in registry.query_radius(spell.caster.global_position, radius):
		var unit := registry.unit_of(handle)
		if unit != null and unit.team == spell.caster.team:
			indicator.unit_ring(handle, TELEPORT, 1.5)
	var destination := indicator.hover if check_target(spell, indicator.hover).is_empty() else _closest_friend(spell)
	if destination != UnitRegistry.NONE:
		indicator.unit_ring(destination, TargetingIndicator.VALID_COLOR, 3.0)
		indicator.line(spell.caster.global_position, registry.position_of(destination), TELEPORT, 2.0)
