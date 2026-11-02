@tool
class_name Checkpoint
extends PartyArea

## A save spot (SAVES.md): when the whole party has gathered here, the game autosaves. In
## multiplayer these (and arriving on a map) are the only places the host's game saves.
## Later candidates: quest completion, doors that need everyone present.

const CHECKPOINT_COLOR := Color(0.5, 0.8, 1.0)


func _init() -> void:
	gather_time = 1.5  # quicker than an exit; a scene can still set its own


func get_symbol() -> String:
	return "✦"


func get_color() -> Color:
	return color if color.a > 0.0 else CHECKPOINT_COLOR


func _on_gathered() -> void:
	Campaign.current.reach_checkpoint()


func countdown_text(_seconds: int) -> String:
	return "Saving…"
