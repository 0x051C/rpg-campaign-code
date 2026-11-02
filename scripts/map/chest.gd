@tool
class_name Chest
extends MapProp

## A chest placed on a map (SAVES.md): when a living hero of the party walks up to it, it
## opens and its `items` spill out in front of it as pickups. The campaign remembers it as
## opened, so it stays open (and empty) after loading or coming back to the map.
## A primitive box with a lid until a real model exists (ASSET_LIST.md).

const TIMBER := preload("res://data/materials/timber.tres")
const OPEN_REACH := 1.4  ## from the chest's edge
const CHECK_TIME := 0.2
const SIZE := Vector3(1.0, 0.6, 0.7)
const LID_HEIGHT := 0.18

## What's inside; assign items in the inspector.
@export var items: Array[ItemDefinition] = []
## Gold inside, spilled as a pile next to the items.
@export var gold := 0
## Random items rolled when it opens (LootRoller, DIRECTION.md 1), on top of `items`: how many, at
## what item level, and with a champion's better odds.
@export var random_items := 0
@export var item_level := 1
@export var better_odds := false

var opened := false

var _base: MeshInstance3D
var _lid_pivot: Node3D
var _timer := 0.0


func _ready() -> void:
	super()
	if Engine.is_editor_hint():
		return
	Simulation.join(self, Simulation.Order.TRIGGERS)
	if Campaign.current.is_opened(self):
		_set_open(false)  # opened on an earlier visit: just show it open


func _simulate(delta: float) -> void:
	if Engine.is_editor_hint() or opened:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = CHECK_TIME
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	if party == null:
		return
	for hero in party.heroes():
		var offset := hero.global_position - global_position
		if hero.is_alive() and Vector2(offset.x, offset.z).length() <= OPEN_REACH + SIZE.x * 0.5:
			open()
			return


## Opens the chest and spills its items in front of it.
func open() -> void:
	if opened:
		return
	_set_open(true)
	Campaign.current.mark_opened(self)
	Sounds.play_at(&"clunk", global_position)
	var contents := items.duplicate()
	for i in random_items:
		var rolled := LootRoller.random_item(item_level, better_odds)
		if better_odds and randf() < LootRoller.CHEST_LEGENDARY:
			rolled = LootRoller.random_legendary(item_level)
		if rolled != null:
			contents.append(rolled)
	var front := global_basis.z.normalized()
	var count := contents.size() + (1 if gold > 0 else 0)
	for i in count:
		var side := (i - (count - 1) * 0.5) * 0.6
		var at := global_position + front * (SIZE.z * 0.5 + 0.9) + global_basis.x.normalized() * side
		if i < contents.size():
			ItemPickup.drop(get_parent(), contents[i], at)
		else:
			ItemPickup.drop_gold(get_parent(), gold, at)


func _set_open(animate: bool) -> void:
	opened = true
	if _lid_pivot == null:
		return
	if animate:
		create_tween().tween_property(_lid_pivot, ^"rotation:x", deg_to_rad(-105.0), 0.4)
	else:
		_lid_pivot.rotation.x = deg_to_rad(-105.0)


func get_selection_faces() -> PackedVector3Array:
	var faces := PackedVector3Array()
	if _base != null:
		for face in _base.mesh.get_faces():
			faces.append(face + _base.position)
	return faces


func _build_visual() -> void:
	if _base != null:
		return
	_base = MeshInstance3D.new()  # generated, not owned, never saved
	var box := BoxMesh.new()
	box.size = Vector3(SIZE.x, SIZE.y - LID_HEIGHT, SIZE.z)
	box.material = TIMBER
	_base.mesh = box
	_base.position = Vector3.UP * (SIZE.y - LID_HEIGHT) * 0.5
	add_child(_base)
	_lid_pivot = Node3D.new()  # hinged at the back edge
	_lid_pivot.position = Vector3(0.0, SIZE.y - LID_HEIGHT, -SIZE.z * 0.5)
	add_child(_lid_pivot)
	var lid := MeshInstance3D.new()
	var lid_box := BoxMesh.new()
	lid_box.size = Vector3(SIZE.x, LID_HEIGHT, SIZE.z)
	lid_box.material = TIMBER
	lid.mesh = lid_box
	lid.position = Vector3(0.0, LID_HEIGHT * 0.5, SIZE.z * 0.5)
	_lid_pivot.add_child(lid)


func _fit_collision(scaling: Vector3) -> void:
	var box := BoxShape3D.new()
	box.size = SIZE * scaling
	_collision.shape = box
	_collision.position = Vector3.UP * SIZE.y * scaling.y * 0.5
