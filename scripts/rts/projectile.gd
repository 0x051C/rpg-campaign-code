class_name Projectile
extends MeshInstance3D

## Homing projectile for ranged attacks between registry handles; deals the attack
## damage on arrival and fizzles if the target died on the way. A target that disjoints
## (Shadow Stance, Reflection) makes it fly on to where the target was and miss. Hidden in
## the fog of war.

const GROUP := &"projectiles"

static var _mesh: SphereMesh

var registry: UnitRegistry
var source := UnitRegistry.NONE
var target := UnitRegistry.NONE
var damage := 0.0
var speed := 20.0
var on_hit := Callable()  ## called with the target when it lands
var _lost_at := Vector3.INF  ## disjointed: flies here and misses
var _at := Vector3.ZERO  ## where it is, as of the last tick
var _was := Vector3.ZERO  ## where it was a tick before: it's drawn in between


static func launch(owner_registry: UnitRegistry, from: int, to: int, attack_damage: float, flight_speed: float, color: Color,
		hit := Callable()) -> void:
	if _mesh == null:
		_mesh = SphereMesh.new()
		_mesh.radius = 0.12
		_mesh.height = 0.24
	var projectile := Projectile.new()
	projectile.mesh = _mesh
	projectile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 2.0
	projectile.material_override = material
	projectile.registry = owner_registry
	projectile.source = from
	projectile.target = to
	projectile.damage = attack_damage
	projectile.speed = flight_speed
	projectile.on_hit = hit
	projectile.add_to_group(GROUP)
	owner_registry.add_child(projectile)
	projectile._at = owner_registry.aim_point(from)
	projectile._was = projectile._at
	projectile.global_position = projectile._at
	projectile.visible = FogOfWar.player_sees(projectile._at)


## noh disjoint: every projectile flying at `handle` loses it and misses.
static func disjoint(tree: SceneTree, handle: int) -> void:
	for node in tree.get_nodes_in_group(GROUP):
		var projectile := node as Projectile
		if projectile.target == handle and projectile._lost_at == Vector3.INF:
			projectile._lost_at = projectile.registry.aim_point(handle)


func _ready() -> void:
	Simulation.join(self, Simulation.Order.PROJECTILES)


func _simulate(delta: float) -> void:
	_was = _at
	if _lost_at != Vector3.INF:
		_fly_off(delta)
		return
	if not registry.is_alive(target):
		queue_free()
		return
	var to_target := registry.aim_point(target) - _at
	var step := speed * delta
	if to_target.length() <= step:
		if registry.apply_damage(target, damage, source) and on_hit.is_valid():
			on_hit.call(target)
		queue_free()
		return
	_at += to_target.normalized() * step
	visible = FogOfWar.player_sees(_at)


func _process(_delta: float) -> void:
	global_position = _was.lerp(_at, Simulation.alpha)  # between the last two ticks


func _fly_off(delta: float) -> void:
	var to_spot := _lost_at - _at
	if to_spot.length() <= speed * delta:
		queue_free()
		return
	_at += to_spot.normalized() * speed * delta
	visible = FogOfWar.player_sees(_at)
