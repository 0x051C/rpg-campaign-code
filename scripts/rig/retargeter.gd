class_name RigRetargeter
extends RefCounted

## Plays animations made for one humanoid skeleton on another with different bones.
##
## The source (KayKit Rig_Medium, driven by an AnimationPlayer) and the target (any biped
## HumanoidMapper understands, e.g. a SkinTokens rig) need no common bone names or rest pose.
## For every mapped bone the source's rotation away from its T-pose is carried over in world
## space, after turning the target's own rest direction onto the source's T-pose direction.
## So a target standing in an A-pose is first imagined in a T-pose, then animated, which keeps
## arms from doubling up. Hips movement is scaled by the ratio of the two hip heights.
##
## Arms of a target standing in an A-pose (arms down at rest) are retargeted relative to the source's
## idle pose instead: at rest they match the source standing idle, so the character keeps its own arm
## angle and the motion is added on top. Otherwise a slim character would copy a chunky character's
## arms-out stance, and sleeves skinned to the arms would spread like wings.
##
## Usage: setup() once, then apply() after the source skeleton has been updated each frame.

## The KayKit bone that drives each mapped bone, and the bone the direction of each limb piece
## points to (leaf bones reuse their parent's direction).
const SOURCE_BONES := {
	"hips": "hips", "spine": "spine", "chest": "chest", "head": "head",
	"upperarm.l": "upperarm.l", "lowerarm.l": "lowerarm.l", "hand.l": "hand.l",
	"upperarm.r": "upperarm.r", "lowerarm.r": "lowerarm.r", "hand.r": "hand.r",
	"upperleg.l": "upperleg.l", "lowerleg.l": "lowerleg.l", "foot.l": "foot.l", "toes.l": "toes.l",
	"upperleg.r": "upperleg.r", "lowerleg.r": "lowerleg.r", "foot.r": "foot.r", "toes.r": "toes.r",
}
const POINTS_TO := {
	"hips": "spine", "spine": "chest", "chest": "head",
	"upperarm.l": "lowerarm.l", "lowerarm.l": "hand.l", "upperarm.r": "lowerarm.r", "lowerarm.r": "hand.r",
	"upperleg.l": "lowerleg.l", "lowerleg.l": "foot.l", "foot.l": "toes.l",
	"upperleg.r": "lowerleg.r", "lowerleg.r": "foot.r", "foot.r": "toes.r",
}
const LEAF_PARENT := {"head": "chest", "hand.l": "lowerarm.l", "hand.r": "lowerarm.r", "toes.l": "foot.l", "toes.r": "foot.r"}
const ARM_BONES: Array[String] = ["upperarm.l", "lowerarm.l", "hand.l", "upperarm.r", "lowerarm.r", "hand.r"]
const IDLE_REFERENCE := ["Idle_A", 0.0]  ## animation and time standing for "arms relaxed at the sides"
const A_POSE_DEGREES := 30.0  ## a rest arm this far below horizontal makes the arms idle-relative
## Idle-relative arms keep this share of the source's sideways arm movement (forward/back swing is kept
## whole): a chunky source swings its arms out to clear its body, a slim target needn't.
const ARM_SIDEWAYS_SHARE := 0.3

var mapping: Dictionary[String, int] = {}  ## KayKit name -> target bone

var _source: Skeleton3D
var _target: Skeleton3D
var _source_index: Dictionary[String, int] = {}
var _source_t_rotation: Dictionary[String, Quaternion] = {}
var _source_t_hips := Vector3.ZERO
var _align := Quaternion.IDENTITY  ## turns the target's facing onto the source's
var _fix: Dictionary[String, Quaternion] = {}  ## per bone: target rest direction onto the source's T-pose direction
var _rest_rotation: Array[Quaternion] = []
var _bone_of: Dictionary[int, String] = {}
var _order: Array[int] = []
var _hip_scale := 1.0
var _hips_rest := Vector3.ZERO
var arms_from_idle := false  ## true when the target's arms are retargeted relative to the source's idle pose
var _idle_direction: Dictionary[String, Vector3] = {}  ## source arm piece directions in the idle pose
var _source_left := Vector3.RIGHT  ## the source character's left, in its own space


## `source` must be in its T-pose when this is called (play the T-Pose animation first). Pass the
## source's AnimationPlayer to let A-pose targets use its idle pose as the arms' reference.
## Returns false if the target is not a biped the mapper can read.
func setup(source: Skeleton3D, target: Skeleton3D, player: AnimationPlayer = null) -> bool:
	_source = source
	_target = target
	mapping = HumanoidMapper.map(target)
	if mapping.is_empty():
		return false
	for key: String in SOURCE_BONES:
		var index := source.find_bone(SOURCE_BONES[key])
		if index < 0:
			return false
		_source_index[key] = index
		_source_t_rotation[key] = _rotation(source.get_bone_global_pose(index))
	_source_t_hips = source.get_bone_global_pose(_source_index["hips"]).origin
	for key: String in mapping:
		_bone_of[mapping[key]] = key

	# Which way each skeleton faces, from heel to toes
	_align = _facing_alignment()

	for key: String in mapping:
		if not _source_index.has(key):
			continue
		var target_direction := _direction(target, key, true)
		var source_direction := _direction(source, key, false)
		if target_direction.length() < 0.0001 or source_direction.length() < 0.0001:
			_fix[key] = Quaternion.IDENTITY
		else:
			_fix[key] = Quaternion(_align * target_direction.normalized(), source_direction.normalized())

	# A-pose arms: their rest stands for the source's idle pose, with no correction to it
	arms_from_idle = player != null and player.has_animation(IDLE_REFERENCE[0]) and _arms_hang_down(target)
	if arms_from_idle:
		var current := player.current_animation
		var position_now := player.current_animation_position
		player.play(IDLE_REFERENCE[0])
		player.seek(IDLE_REFERENCE[1], true)
		for key in ARM_BONES:
			_source_t_rotation[key] = _rotation(source.get_bone_global_pose(_source_index[key]))
			_idle_direction[key] = _direction(source, key, false).normalized()
			_fix[key] = Quaternion.IDENTITY
		var across := _bone_position(source, "upperarm.l", false) - _bone_position(source, "upperarm.r", false)
		across.y = 0.0
		if across.length() > 0.0001:
			_source_left = across.normalized()
		player.play(current)
		player.seek(position_now, true)
		player.pause()

	_rest_rotation.clear()
	for i in target.get_bone_count():
		_rest_rotation.append(target.get_bone_rest(i).basis.orthonormalized().get_rotation_quaternion())
	_order = _parents_first(target)
	var hips := target.get_bone_global_rest(mapping["hips"]).origin
	var ground_target := _lowest(target)
	var ground_source := _lowest(source)
	_hips_rest = hips
	_hip_scale = (hips.y - ground_target) / maxf(_source_t_hips.y - ground_source, 0.001)
	return true


## Poses the target to match the source's current pose.
func apply() -> void:
	var count := _target.get_bone_count()
	var global_transform: Array[Transform3D] = []
	global_transform.resize(count)
	var align_inverse := _align.inverse()
	for i in _order:
		var parent := _target.get_bone_parent(i)
		var parent_transform := global_transform[parent] if parent >= 0 else Transform3D.IDENTITY
		var parent_rotation := parent_transform.basis.orthonormalized().get_rotation_quaternion()
		var rest := _target.get_bone_rest(i)
		var wanted_rotation: Quaternion
		var position := rest.origin
		if _bone_of.has(i) and _source_index.has(_bone_of[i]):
			var key := _bone_of[i]
			var moved := _rotation(_source.get_bone_global_pose(_source_index[key])) * _source_t_rotation[key].inverse()
			if arms_from_idle and _idle_direction.has(key):
				moved = _damp_sideways(moved, _idle_direction[key])
			var global_rest := _target.get_bone_global_rest(i).basis.orthonormalized().get_rotation_quaternion()
			wanted_rotation = align_inverse * moved * _fix[key] * _align * global_rest
			if key == "hips":
				var shift := _source.get_bone_global_pose(_source_index["hips"]).origin - _source_t_hips
				var wanted := _hips_rest + align_inverse * (shift * _hip_scale)
				position = parent_transform.affine_inverse() * wanted
		else:
			wanted_rotation = parent_rotation * _rest_rotation[i]
		var local := parent_rotation.inverse() * wanted_rotation
		_target.set_bone_pose_rotation(i, local)
		_target.set_bone_pose_position(i, position)
		global_transform[i] = parent_transform * Transform3D(Basis(local), position)


## The source's rotation away from its idle pose with most of the sideways (away from the body)
## part taken out. Only the swing of the arm piece is kept, not its twist.
func _damp_sideways(moved: Quaternion, idle: Vector3) -> Quaternion:
	var now := moved * idle
	var lateral_idle := idle.dot(_source_left)
	var lateral_now := now.dot(_source_left)
	var damped := now + _source_left * ((lateral_idle + (lateral_now - lateral_idle) * ARM_SIDEWAYS_SHARE) - lateral_now)
	if damped.length() < 0.0001:
		return moved
	return Quaternion(idle, damped.normalized())


## Whether the target's upper arms point well below horizontal at rest (an A-pose or arms down).
func _arms_hang_down(target: Skeleton3D) -> bool:
	for side in [".l", ".r"]:
		var direction := _direction(target, "upperarm" + side, true)
		if direction.length() < 0.0001:
			return false
		var below := rad_to_deg(asin(clampf(-direction.normalized().y, -1.0, 1.0)))
		if below < A_POSE_DEGREES:
			return false
	return true


## Direction a limb piece points in the skeleton's rest (target) or T-pose (source) state.
func _direction(skeleton: Skeleton3D, key: String, is_target: bool) -> Vector3:
	var from_key := key
	var to_key: String = POINTS_TO.get(key, "")
	if to_key.is_empty():
		from_key = LEAF_PARENT.get(key, key)
		to_key = key
	var a := _bone_position(skeleton, from_key, is_target)
	var b := _bone_position(skeleton, to_key, is_target)
	return b - a


func _bone_position(skeleton: Skeleton3D, key: String, is_target: bool) -> Vector3:
	var index: int = mapping[key] if is_target else _source_index[key]
	return skeleton.get_bone_global_rest(index).origin if is_target else skeleton.get_bone_global_pose(index).origin


func _facing_alignment() -> Quaternion:
	var target_forward := _forward(_target, true)
	var source_forward := _forward(_source, false)
	return Quaternion(target_forward, source_forward)


func _forward(skeleton: Skeleton3D, is_target: bool) -> Vector3:
	var forward := Vector3.ZERO
	for side in [".l", ".r"]:
		if (is_target and mapping.has("toes" + side)) or (not is_target and _source_index.has("toes" + side)):
			forward += _bone_position(skeleton, "toes" + side, is_target) - _bone_position(skeleton, "foot" + side, is_target)
	forward.y = 0.0
	return forward.normalized() if forward.length() > 0.001 else Vector3.BACK


func _lowest(skeleton: Skeleton3D) -> float:
	var low := INF
	for i in skeleton.get_bone_count():
		low = minf(low, skeleton.get_bone_global_pose(i).origin.y if skeleton == _source else skeleton.get_bone_global_rest(i).origin.y)
	return low


static func _rotation(transform: Transform3D) -> Quaternion:
	return transform.basis.orthonormalized().get_rotation_quaternion()


static func _parents_first(skeleton: Skeleton3D) -> Array[int]:
	var order: Array[int] = []
	var queue: Array[int] = []
	for i in skeleton.get_bone_count():
		if skeleton.get_bone_parent(i) < 0:
			queue.append(i)
	while not queue.is_empty():
		var bone: int = queue.pop_front()
		order.append(bone)
		for child in skeleton.get_bone_children(bone):
			queue.append(child)
	return order
