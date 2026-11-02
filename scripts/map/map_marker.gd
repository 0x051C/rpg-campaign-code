@tool
class_name MapMarker
extends Marker3D

## A point the overlay map shows: a quest giver, a quest objective, a dropped item or
## a point of interest. Place one in a map (scenes/markers, scenes/items) or add one
## as a child of anything that should show up, e.g. loot spawned at runtime.

enum Kind { QUEST, OBJECTIVE, ITEM, POINT_OF_INTEREST }

const GROUP := &"map_markers"
const BEACON_HEIGHT := 3.2
const KIND_COLORS: Dictionary[Kind, Color] = {
	Kind.QUEST: Color(1.0, 0.82, 0.2),
	Kind.OBJECTIVE: Color(1.0, 0.6, 0.15),
	Kind.ITEM: Color(0.85, 0.85, 0.9),
	Kind.POINT_OF_INTEREST: Color(0.6, 0.85, 1.0),
}
const KIND_SYMBOLS: Dictionary[Kind, String] = {
	Kind.QUEST: "!",
	Kind.OBJECTIVE: "?",
	Kind.ITEM: "",
	Kind.POINT_OF_INTEREST: "",
}

@export var kind := Kind.QUEST:
	set(value):
		kind = value
		_update_beacon()
## Shown next to the marker on the overlay map.
@export var title := ""
## Overrides the kind's color, e.g. for item rarity.
@export var color := Color(0, 0, 0, 0):
	set(value):
		color = value
		_update_beacon()
## Quests and objectives float their symbol above the marker in the world too.
@export var show_beacon := true:
	set(value):
		show_beacon = value
		_update_beacon()

var _beacon: Label3D


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	_update_beacon()


func _process(delta: float) -> void:
	if _beacon != null and _beacon.visible:
		_beacon.position.y = _beacon_height() + sin(Time.get_ticks_msec() * 0.003) * 0.15
		_beacon.rotate_y(delta)  # visible from every side


func get_color() -> Color:
	return color if color.a > 0.0 else KIND_COLORS[kind]


func get_symbol() -> String:
	return KIND_SYMBOLS[kind]


func _update_beacon() -> void:
	if not is_inside_tree():
		return
	var wanted := show_beacon and not get_symbol().is_empty()
	if wanted and _beacon == null:
		_beacon = Label3D.new()  # generated, not owned, never saved
		_beacon.font_size = 160
		_beacon.outline_size = 24
		_beacon.pixel_size = 0.01
		_beacon.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		_beacon.no_depth_test = false
		_beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_beacon)
	if _beacon != null:
		_beacon.visible = wanted
		_beacon.text = get_symbol()
		_beacon.modulate = get_color()
		_beacon.position.y = _beacon_height()
	set_process(wanted)


## Floats above the drawn ground, however high the terrain is under the marker.
func _beacon_height() -> float:
	if not is_inside_tree():
		return BEACON_HEIGHT
	return BEACON_HEIGHT + Terrain.ground(global_position.x, global_position.z) - global_position.y
