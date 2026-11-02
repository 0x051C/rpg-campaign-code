@tool
class_name PartyArea
extends MapMarker

## A spot the whole party has to gather at (SAVES.md): every living hero of the party within
## `radius` for `gather_time` seconds. Map exits and checkpoints are PartyAreas, so a single
## hero (later: a single player) can't drag the others along or save with someone far away.
## A ring on the ground shows the area; messages say who is missing or how long is left.
## It fires once per visit: everyone has to step off before it can fire again.

signal gathered

const CHECK_TIME := 0.1
const MESSAGE_TIME := 0.5
const RING := preload("res://shaders/ground_decal.gdshader")

@export var radius := 2.5
@export var gather_time := 5.0
## Off: one hero is enough.
@export var whole_party := true

var _progress := 0.0
var _fired := false
var _timer := 0.0
var _message_timer := 0.0
var _ring: MeshInstance3D
var _ring_material := ShaderMaterial.new()


func _ready() -> void:
	super()
	if not Engine.is_editor_hint():
		_make_ring()
		Simulation.join(self, Simulation.Order.TRIGGERS)


func _simulate(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_timer -= delta
	_message_timer -= delta
	if _timer > 0.0:
		return
	var step := CHECK_TIME - _timer
	_timer = CHECK_TIME
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	if party == null:
		return
	var living := 0
	var inside := 0
	for hero in party.heroes():
		if not hero.is_alive():
			continue
		living += 1
		var offset := hero.global_position - global_position
		if Vector2(offset.x, offset.z).length() <= radius:
			inside += 1
	if inside == 0:
		_progress = 0.0
		_fired = false
	elif not _fired:
		if whole_party and inside < living:
			_progress = 0.0
			_say(waiting_text(inside, living))
		else:
			_progress += step
			if _progress >= gather_time:
				_fired = true
				_progress = 0.0
				_on_gathered()
				gathered.emit()
				if not is_inside_tree():
					return  # travelled: the map is already gone
			else:
				_say(countdown_text(ceili(gather_time - _progress)))
	_update_ring()


## What happens once everyone is here.
func _on_gathered() -> void:
	pass


func waiting_text(inside: int, living: int) -> String:
	return "Waiting for the whole party (%d/%d)" % [inside, living]


func countdown_text(seconds: int) -> String:
	return "%d…" % seconds


func _say(text: String) -> void:
	if _message_timer > 0.0:
		return
	_message_timer = MESSAGE_TIME
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	if party != null:
		party.commander.show_message(text, get_color())


func _make_ring() -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.95
	mesh.outer_radius = 1.0
	mesh.rings = 64
	mesh.ring_segments = 4
	_ring = MeshInstance3D.new()
	_ring.mesh = mesh
	_ring.material_override = _ring_material
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring_material.shader = RING  # follows the terrain
	_ring.top_level = true
	add_child(_ring)
	_update_ring()


func _update_ring() -> void:
	if _ring == null:
		return
	_ring.global_transform = Transform3D(Basis.from_scale(Vector3(radius, 0.2, radius)),
			Vector3(global_position.x, 0.05, global_position.z))
	var tint := get_color()
	tint.a = 0.35 + 0.65 * (_progress / gather_time if gather_time > 0.0 else 0.0)
	_ring_material.set_shader_parameter(&"color", tint)
