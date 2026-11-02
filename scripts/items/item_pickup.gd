@tool
class_name ItemPickup
extends MapMarker

## Something lying on the map: an item or a pile of gold, placed in the editor (scenes/items)
## or dropped at runtime by a dying unit or an opened chest (drop(), drop_gold()).
##
## Hovering it shows its name and a ring under it. Items are picked up by smart-clicking them:
## the nearest selected hero walks over (Unit PICKUP order, the ring stays lit meanwhile)
## and puts it in the party bag if the weight allows. Gold is simpler: walking over it is
## enough. Runtime drops are saved with the map; ones left behind wait at the entrance when
## the party comes back (Campaign).

const PICKUP_GROUP := &"item_pickups"  ## everything that can be picked up
const RUNTIME_GROUP := &"dropped_items"  ## loot dropped while playing (not placed in the editor)
const PICKUP_RANGE := 1.6
const CHECK_TIME := 0.2
const GOLD_COLOR := Color(1.0, 0.82, 0.25)
const RING := preload("res://shaders/ground_decal.gdshader")
const RING_RADIUS := 0.55

@export var item: ItemDefinition
## A pile of gold instead of an item: picked up by walking over it, weighs nothing.
@export var gold := 0

var _timer := 0.0
var _hover_frame := -100
var _target_tick := -100
var _ring: MeshInstance3D
var _ring_material := ShaderMaterial.new()


## Drops `item` on the ground at `at` (a small glowing box in the item's color).
static func drop(parent: Node, item_to_drop: ItemDefinition, at: Vector3, quiet := false) -> ItemPickup:
	var pickup := ItemPickup.new()
	pickup.item = item_to_drop
	var box := BoxMesh.new()
	box.size = Vector3(0.35, 0.35, 0.35)
	var visual := MeshInstance3D.new()
	visual.mesh = box
	visual.material_override = _glowing(item_to_drop.icon_color)
	visual.position = Vector3.UP * 0.2
	visual.rotation.y = randf() * TAU
	pickup.add_child(visual)
	return _place(pickup, parent, at, quiet)


## Drops `amount` gold on the ground at `at`.
static func drop_gold(parent: Node, amount: int, at: Vector3, quiet := false) -> ItemPickup:
	var pickup := ItemPickup.new()
	pickup.gold = amount
	return _place(pickup, parent, at, quiet)


static func _place(pickup: ItemPickup, parent: Node, at: Vector3, quiet := false) -> ItemPickup:
	if not quiet:
		Sounds.play_at(&"item_drop", at)
	pickup.kind = Kind.ITEM
	pickup.show_beacon = false
	pickup.add_to_group(RUNTIME_GROUP)
	parent.add_child(pickup)
	pickup.global_position = Vector3(at.x, Terrain.ground(at.x, at.z), at.z)
	return pickup


static func _glowing(tint: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	material.emission_enabled = true
	material.emission = tint
	material.emission_energy_multiplier = 0.6
	return material


func _enter_tree() -> void:
	super()
	add_to_group(PICKUP_GROUP)


func _ready() -> void:
	if title.is_empty():
		title = display_name()
	super()
	if gold > 0 and find_children("*", "MeshInstance3D", true, false).is_empty():
		_build_coins()
	set_process(not Engine.is_editor_hint())  # the hover ring (MapMarker turns processing off without a beacon)
	if not Engine.is_editor_hint():
		Simulation.join(self, Simulation.Order.TRIGGERS)


## "Militia Sword", or "25 gold".
func display_name() -> String:
	if gold > 0:
		return "%d gold" % gold
	return item.display_name if item != null else "?"


func name_color() -> Color:
	if gold > 0:
		return GOLD_COLOR
	if item == null:
		return Color.WHITE
	if item.rarity != ItemDefinition.Rarity.COMMON:  # Diablo's colors on the ground: blue, yellow
		return item.name_color()
	return item.icon_color.lightened(0.35)


## Where a hero stands to pick it up: the spot on the gameplay plane.
func ground_spot() -> Vector3:
	return Vector3(global_position.x, 0.0, global_position.z)


## Gold is picked up by walking over it; items by smart-clicking them.
func walk_over() -> bool:
	return gold > 0


## The cursor is on it this frame (Commander): show the ring.
func mark_hovered() -> void:
	_hover_frame = Engine.get_process_frames()


## A hero is on its way to pick it up (Unit PICKUP order): keep the ring lit.
func mark_targeted() -> void:
	_target_tick = Simulation.ticks


## `hero` picks it up: gold into the purse, an item into the bag if the weight allows.
## Returns "" or why not.
func pick_up(hero: Unit) -> String:
	if is_queued_for_deletion():
		return ""
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	if party == null or not hero.is_alive():
		return "Nobody can pick that up"
	if gold > 0:
		party.add_gold(gold)
		party.commander.show_message("+%d gold" % gold, GOLD_COLOR)
	elif item == null:
		return ""
	elif not party.add(item):
		return "Too heavy: the party can't carry %s too" % item.display_name
	else:
		party.commander.show_message("Picked up %s" % item.display_name, PartyInventory.GOOD_NEWS)
	if not is_in_group(RUNTIME_GROUP):
		Campaign.current.mark_taken(self)  # placed in the editor: stays gone, also after loading or coming back
	queue_free()
	return ""


## As plain data for saves and the loot left behind (Campaign).
func save_state() -> Dictionary:
	return {"item": SaveCodec.encode_resource(item), "gold": gold, "position": global_position}


static func from_state(parent: Node, data: Dictionary, at: Vector3) -> ItemPickup:
	if data.get("gold", 0) > 0:
		return drop_gold(parent, data.gold, at, true)
	return drop(parent, SaveCodec.decode_resource(data.item) as ItemDefinition, at, true)  # put back, not dropped


func _process(delta: float) -> void:
	super(delta)
	if Engine.is_editor_hint():
		return
	var hovered := Engine.get_process_frames() - _hover_frame <= 1
	var targeted := Simulation.ticks - _target_tick <= 2
	if not hovered and not targeted:
		if _ring != null:
			_ring.visible = false
		return
	if _ring == null:
		_make_ring()
	_ring.visible = true
	var tint := name_color()
	tint.a = 1.0 if targeted else 0.55
	_ring_material.set_shader_parameter(&"color", tint)
	_ring.global_transform = Transform3D(Basis.from_scale(Vector3(RING_RADIUS, 0.2, RING_RADIUS)),
			ground_spot() + Vector3.UP * 0.05)


func _simulate(delta: float) -> void:
	if Engine.is_editor_hint() or not walk_over():
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
		if hero.is_alive() and Vector2(offset.x, offset.z).length() <= PICKUP_RANGE:
			pick_up(hero)
			return


func _make_ring() -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = 0.85
	mesh.outer_radius = 1.0
	mesh.rings = 32
	mesh.ring_segments = 4
	_ring = MeshInstance3D.new()
	_ring.mesh = mesh
	_ring.top_level = true
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ring_material.shader = RING  # follows the terrain
	_ring.material_override = _ring_material
	add_child(_ring)


## A small stack of coins, for gold placed or dropped without a model.
func _build_coins() -> void:
	var material := _glowing(GOLD_COLOR)
	for i in 3:
		var coin := MeshInstance3D.new()
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = 0.14
		cylinder.bottom_radius = 0.14
		cylinder.height = 0.05
		cylinder.radial_segments = 12
		coin.mesh = cylinder
		coin.material_override = material
		coin.position = Vector3(0.08 * (i - 1), 0.03 + 0.05 * i, 0.04 * (i % 2))
		add_child(coin)
