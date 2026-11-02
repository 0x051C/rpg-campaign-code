class_name CharacterModel
extends Node3D

## The root of a character prefab whose model brings its own animations (the anime heroes,
## exported from Dota 2 mods in assets/characters/anime), instead of the shared KayKit
## Rig_Medium libraries. `clips` maps the clip names the game plays to the model's own
## clips; UnitAnimations.attach() adds them to the model's AnimationPlayer under those names.
##
## Game clips: the ones in UnitAnimations.CLIPS (idle, run, death, attack, cast, channel),
## and per ability, by its file name (AbilityDefinition.id()):
##   "abilities/<id>"          its cast gesture, played from the start of the cast;
##   "abilities/<id>_channel"  looped while it channels;
##   "abilities/<id>_strike"   each blow of Swift Slashes;
##   for an attack modifier (Searing Arrows), the attack while it's charged.
## A value may name several clips separated by spaces; one is picked at random each time
## (attacks that alternate, like Dota's attack_01 / attack_02).

## Game clip -> this model's clip(s). Game clips left out fall back to the idle (abilities:
## to the generic cast and channel).
@export var clips: Dictionary[StringName, StringName] = {}
## What the character says (HeroVoice); none: silent.
@export var voice: VoiceSet
## Colors multiplied into the materials of the meshes whose names start with the key: the modular
## townsfolk's grey hair textures ("Hair_" -> brown) are made to be tinted.
@export var tints: Dictionary[String, Color] = {}

static var _libraries: Dictionary[String, Dictionary] = {}  ## prefab path -> library name -> AnimationLibrary
static var _tinted: Dictionary[String, Material] = {}  ## "<material id> <color>" -> its tinted copy, shared


func _ready() -> void:
	if tints.is_empty():
		return
	for mesh: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		for prefix in tints:
			if not mesh.name.begins_with(prefix):
				continue
			for surface in mesh.mesh.get_surface_count():
				var material := mesh.get_active_material(surface) as BaseMaterial3D
				if material == null:
					continue
				var key := "%d %s" % [material.get_instance_id(), tints[prefix].to_html()]
				if not _tinted.has(key):
					var tinted := material.duplicate() as BaseMaterial3D
					tinted.albedo_color *= tints[prefix]
					_tinted[key] = tinted
				mesh.set_surface_override_material(surface, _tinted[key])


## The model's AnimationPlayer with the game's clip names added (built once per prefab).
func animation_player() -> AnimationPlayer:
	var player: AnimationPlayer = get_node(^"AnimationPlayer")
	if player.has_animation_library(&"general"):
		return player
	var libraries: Dictionary = _libraries.get(scene_file_path, {})
	if libraries.is_empty():
		libraries = _build_libraries(player)
		if not scene_file_path.is_empty():
			_libraries[scene_file_path] = libraries
	for library_name: StringName in libraries:
		player.add_animation_library(library_name, libraries[library_name])
	return player


func _build_libraries(player: AnimationPlayer) -> Dictionary:
	var libraries := {}
	var game_clips: Array[StringName] = UnitAnimations.CLIPS.duplicate()
	for game_clip in clips:
		if not game_clips.has(game_clip):
			game_clips.append(game_clip)
	for game_clip in game_clips:
		var sources := String(clips.get(game_clip, clips.get(UnitAnimations.IDLE, &""))).split(" ", false)
		var library_name := StringName(game_clip.get_slice("/", 0))
		var clip_name := game_clip.get_slice("/", 1)
		var looping := UnitAnimations.LOOPING.has(StringName(clip_name)) or clip_name.ends_with("_channel")
		for i in sources.size():
			if not player.has_animation(sources[i]):
				push_warning("%s: no clip \"%s\" for %s" % [scene_file_path, sources[i], game_clip])
				continue
			var animation := player.get_animation(sources[i])
			if looping:
				animation = animation.duplicate()  # the same clip may also play once elsewhere
				animation.loop_mode = Animation.LOOP_LINEAR
			if not libraries.has(library_name):
				libraries[library_name] = AnimationLibrary.new()
			var variant_name := clip_name if i == 0 else "%s_%d" % [clip_name, i + 1]
			(libraries[library_name] as AnimationLibrary).add_animation(StringName(variant_name), animation)
	return libraries
