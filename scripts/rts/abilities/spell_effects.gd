class_name SpellEffects
extends RefCounted

## Spell visuals built from GPU particles: light pillars, expanding rings, things falling from
## the sky, and lasting bubbles. Every particle is a camera-facing billboard drawn with
## particle_billboard.gdshader, whose texture alpha picks per texel between additive glow
## (A < 0.5) and alpha blending (A >= 0.5). One-shot effects free themselves when done.

const SHADER := preload("res://shaders/particle_billboard.gdshader")
const GLOW := preload("res://assets/textures/particles/glow.png")
const SPARK := preload("res://assets/textures/particles/spark.png")
const RAY := preload("res://assets/textures/particles/ray.png")
const STAR := preload("res://assets/textures/particles/star.png")
const SMOKE := preload("res://assets/textures/particles/smoke.png")
const ICE_SHARD := preload("res://assets/textures/particles/ice_shard.png")

static var _materials: Dictionary[Texture2D, ShaderMaterial] = {}
static var _fade: GradientTexture1D
static var _shrink: CurveTexture


## A column of light, e.g. Holy Light or a resurrection.
static func pillar(parent: Node, at: Vector3, color: Color, radius := 0.6, height := 6.0, duration := 0.7) -> void:
	var effect := _effect(parent, Terrain.lift(at))
	var rays := _motion(color)
	rays.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	rays.emission_ring_axis = Vector3.UP
	rays.emission_ring_radius = radius * 0.8
	rays.emission_ring_inner_radius = radius * 0.3
	rays.emission_ring_height = 0.0
	rays.direction = Vector3.UP
	rays.spread = 3.0
	rays.initial_velocity_min = height / duration * 0.5
	rays.initial_velocity_max = height / duration * 0.9
	_emitter(effect, RAY, rays, 24, duration, Vector2(radius * 0.9, height * 0.5), 0.5)
	var sparks := _motion(color.lightened(0.4))
	sparks.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	sparks.emission_sphere_radius = radius
	sparks.direction = Vector3.UP
	sparks.spread = 25.0
	sparks.initial_velocity_min = 1.0
	sparks.initial_velocity_max = height / duration * 0.4
	sparks.angle_min = -180.0
	sparks.angle_max = 180.0
	_emitter(effect, SPARK, sparks, 30, duration * 1.3, Vector2(0.3, 0.3), 0.3)
	var flash := _motion(color)
	flash.scale_curve = _shrink_curve()
	_emitter(effect, GLOW, flash, 2, duration, Vector2(radius * 4.0, radius * 4.0), 1.0)
	_free_after(effect, duration * 1.3)


## A ring that grows to `radius` along the ground, e.g. a blizzard wave or a teleport.
static func pulse(parent: Node, at: Vector3, radius: float, color: Color, duration := 0.5) -> void:
	var effect := _effect(parent, Terrain.lift(at) + Vector3.UP * 0.2)
	for part: Array in [[GLOW, 64, 0.9, 1.0], [SPARK, 32, 0.35, 1.15]]:
		var ring := _motion(color)
		ring.direction = Vector3.RIGHT
		ring.spread = 180.0
		ring.flatness = 1.0  # outward along the ground in every direction
		ring.initial_velocity_min = radius / duration * part[3]
		ring.initial_velocity_max = radius / duration * part[3]
		ring.angle_min = -180.0
		ring.angle_max = 180.0
		_emitter(effect, part[0], ring, part[1], duration, Vector2(part[2], part[2]), 1.0)
	_free_after(effect, duration)


## Something dropping from the sky onto `at`, leaving a glowing trail and bursting on
## impact: ice shards, stars.
static func fall(parent: Node, at: Vector3, color: Color, size := 0.25, height := 9.0, duration := 0.35, texture: Texture2D = SPARK) -> void:
	var ground := Terrain.lift(at)
	var effect := _effect(parent, ground + Vector3.UP * height)
	var head := _motion(color)
	head.color_ramp = null  # fully visible the whole way down
	var head_emitter := _emitter(effect, texture, head, 1, duration + 0.1, Vector2(size, size) * 4.0, 1.0)
	head_emitter.local_coords = true  # rides with the falling node
	var trail := _motion(color)
	trail.scale_curve = _shrink_curve()
	var trail_emitter := _emitter(effect, GLOW, trail, 16, 0.3, Vector2(size, size) * 3.0, 0.0)
	trail_emitter.one_shot = false
	var tween := effect.create_tween()
	tween.tween_property(effect, ^"global_position", ground, duration).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tween.tween_callback(func() -> void:
		head_emitter.emitting = false
		head_emitter.visible = false
		trail_emitter.emitting = false
		_burst(effect, color, size))
	_free_after(effect, duration + 0.7)


## A shimmering shell around a unit that stays until stop() is called on it, e.g. Divine Shield.
static func bubble(owner: Node3D, radius: float, color: Color, height := 1.2) -> Node3D:
	var effect := Node3D.new()
	effect.name = "SpellEffect"
	owner.add_child(effect)
	effect.position = Vector3.UP * height
	var shell := _motion(color)
	shell.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE
	shell.emission_sphere_radius = radius
	shell.initial_velocity_min = 0.0
	shell.initial_velocity_max = 0.3
	shell.angle_min = -180.0
	shell.angle_max = 180.0
	var sparkles := _emitter(effect, SPARK, shell, 72, 0.9, Vector2(0.42, 0.42), 0.0)
	var haze := _motion(Color(color, color.a * 0.7))
	var glow := _emitter(effect, GLOW, haze, 5, 1.2, Vector2(radius, radius) * 2.8, 0.0)
	for emitter in [sparkles, glow]:
		emitter.one_shot = false
		emitter.local_coords = true  # follows the unit
	return effect


## Lets a lasting effect fade out, then frees it.
static func stop(effect: Node3D) -> void:
	if not is_instance_valid(effect):
		return
	var longest := 0.0
	for emitter in effect.find_children("*", "GPUParticles3D", true, false):
		(emitter as GPUParticles3D).emitting = false
		longest = maxf(longest, (emitter as GPUParticles3D).lifetime)
	_free_after(effect, longest)


# --- Building blocks -------------------------------------------------------------

static func _burst(effect: Node3D, color: Color, size: float) -> void:
	var sparks := _motion(color.lightened(0.3))
	sparks.direction = Vector3.UP
	sparks.spread = 70.0
	sparks.initial_velocity_min = 1.5
	sparks.initial_velocity_max = 4.0
	sparks.gravity = Vector3.DOWN * 9.0
	sparks.angle_min = -180.0
	sparks.angle_max = 180.0
	_emitter(effect, SPARK, sparks, 14, 0.5, Vector2(size, size) * 1.6, 1.0)
	var flash := _motion(color)
	flash.scale_curve = _shrink_curve()
	_emitter(effect, GLOW, flash, 1, 0.35, Vector2(size, size) * 9.0, 1.0)


static func _effect(parent: Node, at: Vector3) -> Node3D:
	var effect := Node3D.new()
	effect.name = "SpellEffect"
	parent.add_child(effect)
	effect.global_position = at
	return effect


## Motion with no gravity, the given color, fading in and out over each particle's life.
static func _motion(color: Color) -> ParticleProcessMaterial:
	var motion := ParticleProcessMaterial.new()
	motion.gravity = Vector3.ZERO
	motion.color = color
	motion.color_ramp = _fade_ramp()
	return motion


static func _emitter(effect: Node3D, texture: Texture2D, motion: ParticleProcessMaterial, amount: int, lifetime: float,
		quad_size: Vector2, explosiveness: float) -> GPUParticles3D:
	var emitter := GPUParticles3D.new()
	emitter.amount = amount
	emitter.lifetime = lifetime
	emitter.one_shot = true
	emitter.explosiveness = explosiveness
	emitter.local_coords = false
	emitter.process_material = motion
	emitter.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH  # the alpha-blended texels need back to front
	emitter.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	emitter.visibility_aabb = AABB(Vector3(-24.0, -4.0, -24.0), Vector3(48.0, 36.0, 48.0))
	var quad := QuadMesh.new()
	quad.size = quad_size
	quad.material = _material(texture)
	emitter.draw_pass_1 = quad
	effect.add_child(emitter)
	emitter.emitting = true
	return emitter


static func _material(texture: Texture2D) -> ShaderMaterial:
	if not _materials.has(texture):
		var material := ShaderMaterial.new()
		material.shader = SHADER
		material.set_shader_parameter(&"texture_albedo", texture)
		_materials[texture] = material
	return _materials[texture]


static func _fade_ramp() -> GradientTexture1D:
	if _fade == null:
		var gradient := Gradient.new()
		gradient.offsets = PackedFloat32Array([0.0, 0.12, 0.65, 1.0])
		gradient.colors = PackedColorArray([Color(1, 1, 1, 0), Color.WHITE, Color.WHITE, Color(1, 1, 1, 0)])
		_fade = GradientTexture1D.new()
		_fade.gradient = gradient
	return _fade


static func _shrink_curve() -> CurveTexture:
	if _shrink == null:
		var curve := Curve.new()
		curve.add_point(Vector2(0.0, 1.0))
		curve.add_point(Vector2(1.0, 0.2))
		_shrink = CurveTexture.new()
		_shrink.curve = curve
	return _shrink


static func _free_after(effect: Node3D, seconds: float) -> void:
	effect.get_tree().create_timer(seconds + 0.2).timeout.connect(effect.queue_free)
