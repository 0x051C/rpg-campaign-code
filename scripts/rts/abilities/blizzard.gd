extends AbilityDefinition

## DotaCraft archmage_blizzard (vscripts/heroes/archmage/blizzard.lua): while
## channeling, ice waves hit every unit in the area, friend or foe, once a second.
## A wave deals at most max_wave_damage in total (ApplyDamageUnitsMax).

const ICE := Color(0.6, 0.85, 1.0, 0.85)
const WAVE_INTERVAL := 1.0
const SHARDS_PER_WAVE := 6
const IMPACT_DELAY := 0.3


func cast(spell: SpellCast) -> void:
	spell.timer = 0.0


func channel(spell: SpellCast, delta: float) -> void:
	spell.timer -= delta
	if spell.timer > 0.0:
		return
	spell.timer = WAVE_INTERVAL
	var registry := spell.registry
	for i in SHARDS_PER_WAVE:
		var offset := Vector2.from_angle(randf() * TAU) * randf() * radius
		SpellEffects.fall(registry, spell.point + Vector3(offset.x, 0.0, offset.y), ICE, 0.2, 9.0, IMPACT_DELAY, SpellEffects.ICE_SHARD)
	registry.get_tree().create_timer(IMPACT_DELAY).timeout.connect(_wave.bind(spell))


func _wave(spell: SpellCast) -> void:
	var registry := spell.registry
	if not is_instance_valid(registry):
		return
	Sounds.play_at(&"ice", spell.point)  # every wave of shards lands
	var victims := registry.query_radius(spell.point, radius)
	if victims.is_empty():
		return
	var damage := spell.value(&"wave_damage")
	var factor := minf(1.0, spell.value(&"max_wave_damage") / (damage * victims.size()))
	for victim in victims:
		registry.apply_damage(victim, damage * factor, spell.caster.handle if is_instance_valid(spell.caster) else UnitRegistry.NONE, false)
	SpellEffects.pulse(registry, spell.point, radius, ICE, 0.4)
