extends Node3D

## Gallery of every character prefab the game uses (scenes/characters). Prefabs are
## inherited scenes of the KayKit models with RightHand / LeftHand bone attachments
## for weapons: open one (right-click it here > Open in Editor) to swap weapons,
## materials or anything else, and every map that uses the unit picks it up. The back row
## are the anime heroes (CharacterModel): Dota 2 mod models with their own animations.
## Run this scene (F6) to see them animated.

const CLIPS: Array[StringName] = [&"general/Idle_A", &"move/Running_A", &"general/Throw", &"general/Use_Item", &"general/Death_A"]
const TURN_SPEED := 0.6

var _players: Array[AnimationPlayer] = []
var _turning := false

@onready var _characters: Node3D = $Characters


func _ready() -> void:
	for model in _characters.get_children():
		_players.append(UnitAnimations.attach(model))
	_play(0)


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var index: int = event.physical_keycode - KEY_1
	if index >= 0 and index < CLIPS.size():
		_play(index)
	elif event.physical_keycode == KEY_SPACE:
		_turning = not _turning


func _process(delta: float) -> void:
	if not _turning:
		return
	for model: Node3D in _characters.get_children():
		model.rotate_y(TURN_SPEED * delta)


func _play(index: int) -> void:
	for player in _players:
		player.play(CLIPS[index], 0.2)
