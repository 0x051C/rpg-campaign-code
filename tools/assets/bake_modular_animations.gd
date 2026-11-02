extends SceneTree

## Bakes the KayKit Rig_Medium clips onto the modular characters' skeleton (Quaternius' Universal
## Base Characters), so townsfolk built from the modular parts animate like any model with its own
## clips (CharacterModel) and pay nothing for retargeting while the game runs.
##
## Every frame of every clip is played on the KayKit rig and carried over by RigRetargeter, the same
## way the rig preview shows it, then the target's bone poses are recorded as tracks. The male and
## female bodies are baked apart: their bones differ in length and rest.
##
##   godot --headless --path . --script res://tools/assets/bake_modular_animations.gd
##
## Writes assets/characters/modular/animations/{male,female}.res (AnimationLibrary, clip names as in
## KayKit: Idle_A, Running_A, Death_A, ...).

const SOURCES: Array[String] = [
	"res://assets/animations/Rig_Medium_General.glb",
	"res://assets/animations/Rig_Medium_MovementBasic.glb",
	"res://assets/animations/Rig_Medium_CombatMelee.glb",
	"res://assets/animations/Rig_Medium_CombatRanged.glb",
	"res://assets/animations/Rig_Medium_Simulation.glb",
	"res://assets/animations/Rig_Medium_Tools.glb",
]
## Body -> a character wearing it (any outfit: the skeleton is the body's).
const BODIES := {
	"male": "res://assets/characters/modular/npcs/brann.glb",
	"female": "res://assets/characters/modular/npcs/mags.glb",
}
const OUT := "res://assets/characters/modular/animations/"
const FPS := 30.0
## Loop, besides the game's own (UnitAnimations.LOOPING): what townsfolk keep doing while they stand.
const AMBIENT_LOOPS: Array[StringName] = [
	&"Sit_Chair_Idle", &"Sit_Floor_Idle", &"Lie_Idle", &"Fishing_Idle", &"Fishing_Reeling", &"Holding_A", &"Holding_B",
	&"Holding_C", &"Chopping", &"Digging", &"Hammering", &"Sawing", &"Pickaxing", &"Lockpicking", &"Working_A",
	&"Working_B", &"Working_C", &"Cheering", &"Waving", &"Melee_Unarmed_Idle", &"Melee_2H_Idle", &"Melee_Blocking",
	&"Ranged_Bow_Idle", &"Ranged_Bow_Aiming_Idle", &"Ranged_Magic_Spellcasting", &"Push_Ups", &"Sit_Ups", &"Jump_Idle",
]
const T_POSE := &"T-Pose"


func _initialize() -> void:
	var source_scene: Node3D = (load(SOURCES[0]) as PackedScene).instantiate()
	root.add_child(source_scene)
	var player: AnimationPlayer = source_scene.find_children("*", "AnimationPlayer", true, false)[0]
	player.active = false  # posed by hand, frame by frame (_pose)
	var source: Skeleton3D = source_scene.find_children("*", "Skeleton3D", true, false)[0]
	var library := player.get_animation_library(&"")
	for path in SOURCES.slice(1):
		var other: Node = (load(path) as PackedScene).instantiate()
		var other_player: AnimationPlayer = other.find_children("*", "AnimationPlayer", true, false)[0]
		for clip in other_player.get_animation_list():
			if not library.has_animation(clip):
				library.add_animation(clip, other_player.get_animation(clip))
		other.free()
	var clips: Array[StringName] = []
	for clip in player.get_animation_list():
		if clip != T_POSE and not String(clip).ends_with("_Pose"):
			clips.append(clip)
	DirAccess.make_dir_recursive_absolute(OUT)
	for body: String in BODIES:
		var target_scene: Node3D = (load(BODIES[body]) as PackedScene).instantiate()
		root.add_child(target_scene)
		var target: Skeleton3D = target_scene.find_children("*", "Skeleton3D", true, false)[0]
		_pose(player, T_POSE, 0.0)
		await process_frame  # the skeleton works out its global poses (what the retargeter reads) in a frame
		var retargeter := RigRetargeter.new()
		if not retargeter.setup(source, target):
			push_error("%s: not a biped the mapper reads" % BODIES[body])
			quit(1)
			return
		var baked := AnimationLibrary.new()
		var skeleton_path := String(target_scene.get_path_to(target))
		for clip in clips:
			baked.add_animation(clip, await _bake(player, clip, retargeter, target, skeleton_path, UnitAnimations.LOOPING.has(clip) or AMBIENT_LOOPS.has(clip)))
		var error := ResourceSaver.save(baked, OUT + body + ".res")
		print("%s: %d clips, skeleton at %s, arms from idle %s -> %s" % [body, clips.size(), skeleton_path,
				retargeter.arms_from_idle, error_string(error)])
		target_scene.free()
	quit()


## Poses the source skeleton straight from the clip's tracks at `time` (no mixer in between: what
## it shows is exactly what the clip says).
func _pose(player: AnimationPlayer, clip: StringName, time: float) -> void:
	var animation := player.get_animation(clip)
	var skeleton: Skeleton3D = player.get_node(player.root_node).find_children("*", "Skeleton3D", true, false)[0]
	skeleton.reset_bone_poses()
	for track in animation.get_track_count():
		var bone := skeleton.find_bone(String(animation.track_get_path(track).get_concatenated_subnames()))
		if bone < 0:
			continue
		match animation.track_get_type(track):
			Animation.TYPE_ROTATION_3D:
				skeleton.set_bone_pose_rotation(bone, animation.rotation_track_interpolate(track, time))
			Animation.TYPE_POSITION_3D:
				skeleton.set_bone_pose_position(bone, animation.position_track_interpolate(track, time))
			Animation.TYPE_SCALE_3D:
				skeleton.set_bone_pose_scale(bone, animation.scale_track_interpolate(track, time))


func _bake(player: AnimationPlayer, clip: StringName, retargeter: RigRetargeter, target: Skeleton3D,
		skeleton_path: String, looping: bool) -> Animation:
	var source_clip := player.get_animation(clip)
	var animation := Animation.new()
	animation.length = source_clip.length
	animation.loop_mode = Animation.LOOP_LINEAR if looping else Animation.LOOP_NONE
	var frames := maxi(int(ceil(source_clip.length * FPS)), 1)
	var rotations: Array[Array] = []  # bone -> [Quaternion per frame]
	var hips: Array[Vector3] = []
	rotations.resize(target.get_bone_count())
	for bone in target.get_bone_count():
		rotations[bone] = []
	var hips_bone: int = retargeter.mapping.get("hips", -1)
	for frame in frames + 1:
		var time := minf(frame / FPS, source_clip.length)
		_pose(player, clip, time)
		await process_frame
		retargeter.apply()
		for bone in target.get_bone_count():
			rotations[bone].append(target.get_bone_pose_rotation(bone))
		hips.append(target.get_bone_pose_position(hips_bone))
	for bone in target.get_bone_count():
		var rest := target.get_bone_rest(bone).basis.get_rotation_quaternion()
		var moves := false
		for rotation: Quaternion in rotations[bone]:
			if not rotation.is_equal_approx(rest):
				moves = true
				break
		if not moves:
			continue  # stays at rest the whole clip: no track needed
		var track := animation.add_track(Animation.TYPE_ROTATION_3D)
		animation.track_set_path(track, "%s:%s" % [skeleton_path, target.get_bone_name(bone)])
		for frame in rotations[bone].size():
			animation.rotation_track_insert_key(track, minf(frame / FPS, animation.length), rotations[bone][frame])
	var position_track := animation.add_track(Animation.TYPE_POSITION_3D)
	animation.track_set_path(position_track, "%s:%s" % [skeleton_path, target.get_bone_name(hips_bone)])
	for frame in hips.size():
		animation.position_track_insert_key(position_track, minf(frame / FPS, animation.length), hips[frame])
	animation.optimize()
	return animation
