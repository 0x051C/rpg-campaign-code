@tool
class_name MapTrigger
extends Node3D

## An invisible area on a map that notices heroes: a circle (`radius`, a distance check on the
## ground) or a box (`size`, turned with the node). When a hero of the party is inside it
## emits `reached`, e.g. for a QuestStep's goal, or wired in the editor's Node > Signals dock
## to CreepSpawner.activate. Drawn as an outline in the editor only.
##
## A `once` trigger remembers that it fired (Campaign flags), so it stays fired after a save
## is loaded or the party comes back to the map.

signal reached(hero: Unit)

enum Shape { CIRCLE, BOX }
enum Who { ANY_HERO, WHOLE_PARTY }

const CHECK_TIME := 0.2
const OUTLINE_COLOR := Color(0.3, 1.0, 0.85, 0.9)

@export var shape := Shape.CIRCLE:
	set(value):
		shape = value
		_update_outline()
## Circle: how far from the trigger a hero counts as there (meters, on the ground).
@export var radius := 3.0:
	set(value):
		radius = value
		_update_outline()
## Box: width (x), height (y, ignored: gameplay is flat) and depth (z), turned with the node.
@export var size := Vector3(6.0, 4.0, 6.0):
	set(value):
		size = value
		_update_outline()
## Any one living hero, or every living hero of the party at once.
@export var who := Who.ANY_HERO
## Fires only the first time; otherwise again each time a hero enters after all left.
@export var once := true
## Off: ignores heroes until enable() (e.g. a QuestStep enables its goal when it starts).
@export var enabled := true
## Clicks when it fires, a pressure plate (a trap, a puzzle).
@export var click := false

var fired := false

var _timer := 0.0
var _inside := false
var _outline: MeshInstance3D


func _ready() -> void:
	if Engine.is_editor_hint():
		_update_outline()
		return
	Simulation.join(self, Simulation.Order.TRIGGERS)
	fired = once and Campaign.current != null and Campaign.current.is_opened(self)


func enable() -> void:
	enabled = true


func disable() -> void:
	enabled = false


## True when `point` (a gameplay position) is inside the area.
func contains(point: Vector3) -> bool:
	if shape == Shape.CIRCLE:
		var offset := point - global_position
		return Vector2(offset.x, offset.z).length() <= radius
	var local := global_transform.affine_inverse() * Vector3(point.x, global_position.y, point.z)
	return absf(local.x) <= size.x * 0.5 and absf(local.z) <= size.z * 0.5


func _simulate(delta: float) -> void:
	if Engine.is_editor_hint() or not enabled or (once and fired):
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = CHECK_TIME
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	if party == null:
		return
	var first: Unit = null
	var living := 0
	var inside := 0
	for hero in party.heroes():
		if not hero.is_alive():
			continue
		living += 1
		if contains(hero.global_position):
			inside += 1
			if first == null:
				first = hero
	var now := inside > 0 and (who == Who.ANY_HERO or inside == living)
	if now and not _inside:
		fired = true
		if once and Campaign.current != null:
			Campaign.current.mark_opened(self)
		if click:
			Sounds.play_at(&"clunk", global_position)
		reached.emit(first)
	_inside = now


# --- Editor outline ------------------------------------------------------------

func _update_outline() -> void:
	if not Engine.is_editor_hint() or not is_inside_tree():
		return
	if _outline == null:
		_outline = MeshInstance3D.new()
		_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = OUTLINE_COLOR
		material.no_depth_test = true
		_outline.material_override = material
		add_child(_outline)  # not owned by the scene: never saved
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var points := PackedVector3Array()
	if shape == Shape.CIRCLE:
		for i in 48:
			points.append(Vector3(cos(TAU * i / 48.0), 0.0, sin(TAU * i / 48.0)) * radius)
	else:
		var half := Vector3(size.x, 0.0, size.z) * 0.5
		points = PackedVector3Array([Vector3(-half.x, 0, -half.z), Vector3(half.x, 0, -half.z),
				Vector3(half.x, 0, half.z), Vector3(-half.x, 0, half.z)])
	for i in points.size():
		for lift in [0.1, 1.5]:
			mesh.surface_add_vertex(points[i] + Vector3.UP * lift)
			mesh.surface_add_vertex(points[(i + 1) % points.size()] + Vector3.UP * lift)
	for i in range(0, points.size(), maxi(floori(points.size() / 8.0), 1)):
		mesh.surface_add_vertex(points[i] + Vector3.UP * 0.1)
		mesh.surface_add_vertex(points[i] + Vector3.UP * 1.5)
	mesh.surface_end()
	_outline.mesh = mesh
