@tool
class_name MapExit
extends PartyArea

## A way to another map: once the whole party has gathered on it for `gather_time` seconds
## (5 by default), it travels there (Campaign.current.travel), taking its progress and items along,
## and arrives at the marker named `arrival` in that map. Arriving is a checkpoint: the game
## autosaves.

const EXIT_COLOR := Color(0.55, 1.0, 0.7)

## The map this leads to.
@export_file("*.tscn") var target_map := ""
## Name of the Marker3D in the target map where the party arrives; empty: its hero start.
@export var arrival := ""


func get_symbol() -> String:
	return "🚪"


func get_color() -> Color:
	return color if color.a > 0.0 else EXIT_COLOR


func _on_gathered() -> void:
	if not target_map.is_empty():
		Campaign.current.travel(target_map, arrival)


func countdown_text(seconds: int) -> String:
	return "%s in %d…" % [title if not title.is_empty() else "Leaving", seconds]
