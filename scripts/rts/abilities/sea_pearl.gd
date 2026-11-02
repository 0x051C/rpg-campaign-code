extends Node3D

## The pearl of Pearl of the Deep, on the map: it floats, shines and goes dark in turns, entrancing
## and drawing in the enemies around it while it shines, a wave breaking over them each time it
## lights up, then sinks when its time is up. Runs on the game's clock (Simulation).

const COLOR := Color(0.55, 0.85, 1.0)
const PULL_SPEED := 2.2  ## meters a second towards the pearl (times `pull`)
const CLOSE := 1.4  ## entranced enemies stop drifting this near it
const ENTRANCED := &"entranced"
const SPLASHES := 10

var caster: Unit
var registry: UnitRegistry
var radius := 7.0
var duration := 6.0
var shine := 1.6
var rest := 0.8
var wave_damage := 50.0
var mana_per_second := 10.0
var pull := 1.0  ## how hard it draws them in (Tidecaller's Pearl: 2)

var _left := 0.0
var _phase := 0.0  ## time into the current shine or rest
var _shining := false
var _orb: MeshInstance3D
var _light: OmniLight3D
var _shimmer: Node3D


func _ready() -> void:
	_left = duration
	_build()
	Simulation.join(self, Simulation.Order.TRIGGERS)
	_light_up()


## Lasts `seconds` more (Tidecaller's Pearl).
func extend(seconds: float) -> void:
	_left += seconds
	duration += seconds


func _simulate(delta: float) -> void:
	if registry == null or not is_instance_valid(registry):
		queue_free()
		return
	_left -= delta
	if _left <= 0.0:
		SpellEffects.pulse(registry, global_position, radius * 0.6, COLOR, 0.5)
		queue_free()
		return
	_phase += delta
	if _shining and _phase >= shine:
		_shining = false
		_phase = 0.0
		_light.light_energy = 0.4
	elif not _shining and _phase >= rest:
		_light_up()
	var center := Vector3(global_position.x, 0.0, global_position.z)
	for other in registry.query_radius(center, radius):
		var their_team := registry.team_of(other)
		if caster != null and is_instance_valid(caster) and UnitRegistry.are_enemies(their_team, caster.team):
			if _shining:
				registry.add_effect(other, ENTRANCED, 0.25, caster.handle, {"stun": true})
				var toward := center - registry.position_of(other)
				toward.y = 0.0
				if toward.length() > CLOSE:
					registry.drag(other, toward.normalized() * minf(PULL_SPEED * pull * delta, toward.length() - CLOSE))
		elif caster != null and is_instance_valid(caster) and their_team == caster.team:
			var friend := registry.unit_of(other)
			if friend != null and friend.max_mana > 0.0:
				friend.mana = minf(friend.mana + mana_per_second * delta, friend.max_mana)
	if _orb != null:
		_orb.position.y = 1.7 + sin((duration - _left) * 2.2) * 0.15


## It shines again: a wave breaks over the enemies around it.
func _light_up() -> void:
	_shining = true
	_phase = 0.0
	if _light != null:
		_light.light_energy = 3.0
	SpellEffects.pulse(registry, global_position, radius, COLOR, 0.6)
	SpellEffects.pillar(registry, global_position, COLOR, 0.5, 3.0, 0.5)
	for i in SPLASHES:  # the sea answers: water falls all over its reach
		var angle := randf() * TAU
		var spot := global_position + Vector3(cos(angle), 0.0, sin(angle)) * randf_range(0.5, radius)
		SpellEffects.fall(registry, spot, COLOR, 0.35, 5.0, randf_range(0.25, 0.45), SpellEffects.GLOW)
	Sounds.play_at(&"splash", global_position)
	if caster == null or not is_instance_valid(caster):
		return
	for other in registry.query_radius(Vector3(global_position.x, 0.0, global_position.z), radius):
		if UnitRegistry.are_enemies(registry.team_of(other), caster.team):
			registry.apply_damage(other, wave_damage, caster.handle, false)
			registry.flash(other, COLOR)


func _build() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.95, 0.97, 1.0)
	material.metallic = 0.4
	material.roughness = 0.08
	material.emission_enabled = true
	material.emission = COLOR
	material.emission_energy_multiplier = 1.2
	material.rim_enabled = true
	material.rim = 0.8
	var sphere := SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.7
	sphere.material = material
	_orb = MeshInstance3D.new()
	_orb.mesh = sphere
	_orb.position.y = 1.7
	add_child(_orb)
	_shimmer = SpellEffects.bubble(_orb, 0.7, Color(COLOR, 0.6), 0.0)
	_light = OmniLight3D.new()
	_light.light_color = COLOR
	_light.light_energy = 3.0
	_light.omni_range = radius + 2.0
	_light.position.y = 2.0
	add_child(_light)
