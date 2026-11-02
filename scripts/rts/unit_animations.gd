class_name UnitAnimations
extends RefCounted

## Shared KayKit Rig_Medium animation libraries. The character models ship without
## animations; the rig clips live in separate files whose tracks target the same
## "Rig_Medium/Skeleton3D" path, so one library drives every character. Models with
## their own animations (CharacterModel) map their clips to the same names instead.

const SOURCES: Dictionary[StringName, String] = {
	&"general": "res://assets/animations/Rig_Medium_General.glb",
	&"move": "res://assets/animations/Rig_Medium_MovementBasic.glb",
	&"ranged": "res://assets/animations/Rig_Medium_CombatRanged.glb",
}
## The clips the game plays; every model must answer to these names.
const IDLE := &"general/Idle_A"
const CLIPS: Array[StringName] = [
	IDLE, &"move/Running_A", &"general/Death_A", &"general/Throw", &"general/Use_Item", &"general/Interact",
]
const LOOPING: Array[StringName] = [
	&"Idle_A", &"Idle_B", &"Running_A", &"Running_B", &"Walking_A", &"Walking_B", &"Walking_C",
]

static var _libraries: Dictionary[StringName, AnimationLibrary] = {}


## `clip` or, for a model with variants of it (CharacterModel: "<clip>_2", "<clip>_3"...),
## one of them at random.
static func variant(player: AnimationPlayer, clip: StringName) -> StringName:
	var count := 1
	while player.has_animation(StringName("%s_%d" % [clip, count + 1])):
		count += 1
	var pick := randi() % count
	return clip if pick == 0 else StringName("%s_%d" % [clip, pick + 1])


## The model's own clip for `ability` ("abilities/<id><suffix>", CharacterModel), or `fallback`.
static func ability_clip(player: AnimationPlayer, ability: AbilityDefinition, suffix: String,
		fallback: StringName) -> StringName:
	if ability == null:
		return fallback
	var clip := StringName("abilities/%s%s" % [ability.id(), suffix])
	return variant(player, clip) if player.has_animation(clip) else fallback


## Adds an AnimationPlayer with the shared libraries to an instantiated character model.
static func attach(model: Node) -> AnimationPlayer:
	if model is CharacterModel:
		return (model as CharacterModel).animation_player()
	if _libraries.is_empty():
		_load_libraries()
	var player := AnimationPlayer.new()
	player.name = &"AnimationPlayer"
	model.add_child(player)
	for library_name in _libraries:
		player.add_animation_library(library_name, _libraries[library_name])
	return player


static func _load_libraries() -> void:
	for library_name in SOURCES:
		var scene: Node = load(SOURCES[library_name]).instantiate()
		var source: AnimationPlayer = scene.find_child("AnimationPlayer", true, false)
		var library := source.get_animation_library(&"")
		for animation_name in LOOPING:
			if library.has_animation(animation_name):
				library.get_animation(animation_name).loop_mode = Animation.LOOP_LINEAR
		_libraries[library_name] = library
		scene.free()
