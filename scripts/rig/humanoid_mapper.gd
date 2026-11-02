class_name HumanoidMapper
extends RefCounted

## Finds the humanoid bones of an unknown skeleton (e.g. one predicted by SkinTokens, whose
## bones are just bone_0 ... bone_N) from its shape alone: where the joints are and how
## they branch. Returns the KayKit Rig_Medium names the animations are keyed to:
## hips, spine, chest, head, upperarm.l/r, lowerarm.l/r, hand.l/r, upperleg.l/r,
## lowerleg.l/r, foot.l/r, toes.l/r. Extra bones (fingers, hair, cloth) are left unmapped.
##
## The skeleton must be a biped standing up along +Y, which is what glTF holds.

## A first arm piece shorter than this share of the next two pieces' average is a collarbone.
const COLLAR_SHARE := 0.6
const LONG_SEGMENT_SHARE := 0.4  ## arm segments at least this long (vs the longest) are limb, shorter ones are fingers
const MIN_LEG_DROP := 0.1  ## a branch off the hips is a leg if it reaches this share of the body height below them


## Skeletons whose bones go by a known naming scheme, mapped by name (shape alone misreads them:
## a hand with five fingers, raised in a T-pose, looks like a chest). KayKit name -> their name.
const NAMED_SCHEMES: Array[Dictionary] = [
	{  # Unreal's mannequin, used by Quaternius' Universal Base Characters
		"hips": "pelvis", "spine": "spine_01", "chest": "spine_03", "head": "Head",
		"upperarm.l": "upperarm_l", "lowerarm.l": "lowerarm_l", "hand.l": "hand_l",
		"upperarm.r": "upperarm_r", "lowerarm.r": "lowerarm_r", "hand.r": "hand_r",
		"upperleg.l": "thigh_l", "lowerleg.l": "calf_l", "foot.l": "foot_l", "toes.l": "ball_l",
		"upperleg.r": "thigh_r", "lowerleg.r": "calf_r", "foot.r": "foot_r", "toes.r": "ball_r",
	},
]


## Mapping from KayKit bone name to the skeleton's bone index; empty if no biped was found.
static func map(skeleton: Skeleton3D) -> Dictionary[String, int]:
	for scheme in NAMED_SCHEMES:
		var named := _by_name(skeleton, scheme)
		if not named.is_empty():
			return named
	var result: Dictionary[String, int] = {}
	var count := skeleton.get_bone_count()
	if count < 10:
		return result
	var position: Array[Vector3] = []
	var children: Array[PackedInt32Array] = []
	for i in count:
		position.append(skeleton.get_bone_global_rest(i).origin)
		children.append(skeleton.get_bone_children(i))
	var low := INF
	var high := -INF
	for p in position:
		low = minf(low, p.y)
		high = maxf(high, p.y)
	var height := high - low
	if height <= 0.0:
		return result

	# The chest is where the neck and both arms branch: the highest joint with three or more branches
	var chest := -1
	for i in count:
		if children[i].size() >= 3 and (chest < 0 or position[i].y > position[chest].y):
			chest = i
	if chest < 0:
		return result

	# The hips are the chest's ancestor where the legs branch off and reach down
	var spine_path: Array[int] = []  # from the chest down to the hips' child on that path
	var hips := -1
	var legs: Array[int] = []
	var below := chest
	var at := skeleton.get_bone_parent(chest)
	spine_path.append(chest)
	while at >= 0:
		var leg_branches: Array[int] = []
		for child in children[at]:
			if child != below and _subtree_extreme(child, children, position, true) < position[at].y - MIN_LEG_DROP * height:
				leg_branches.append(child)
		if not leg_branches.is_empty():
			hips = at
			legs = _split_legs(leg_branches, children, position, position[at].y - MIN_LEG_DROP * height)
			break
		spine_path.append(at)
		below = at
		at = skeleton.get_bone_parent(at)
	if hips < 0 or legs.size() != 2:
		return {}
	result["hips"] = hips
	result["spine"] = spine_path[spine_path.size() - 1]
	result["chest"] = chest

	# Left and right follow from which way the character faces, read off the feet
	var left_axis := _left_axis(legs, children, position)

	# The neck and head rise; the arms reach sideways
	var head_start := _tallest_child(chest, children, position)
	var arms: Array[int] = []
	for child in children[chest]:
		if child != head_start:
			arms.append(child)
	if arms.size() != 2:
		return {}
	result["head"] = head_start

	for side in 2:
		var suffix := ".l" if side == 0 else ".r"
		var sign_of_side := 1.0 if side == 0 else -1.0
		var arm := arms[0] if (position[arms[0]] - position[chest]).dot(left_axis) * sign_of_side > (position[arms[1]] - position[chest]).dot(left_axis) * sign_of_side else arms[1]
		var arm_chain := _chain(arm, children)
		if arm_chain.size() >= 4 and _is_collarbone(arm_chain, position):
			arm_chain.remove_at(0)
		if arm_chain.size() < 3:
			return {}
		var joints := _arm_joints(arm_chain, position)
		result["upperarm" + suffix] = joints[0]
		result["lowerarm" + suffix] = joints[1]
		result["hand" + suffix] = joints[2]

		var leg := legs[0] if (position[legs[0]] - position[hips]).dot(left_axis) * sign_of_side > (position[legs[1]] - position[hips]).dot(left_axis) * sign_of_side else legs[1]
		var leg_chain := _chain(leg, children)
		if leg_chain.size() < 3:
			return {}
		result["upperleg" + suffix] = leg_chain[0]
		result["lowerleg" + suffix] = leg_chain[1]
		result["foot" + suffix] = leg_chain[2]
		var toes := _toes(leg_chain[2], children, position)
		if toes >= 0:
			result["toes" + suffix] = toes
	return result


## The scheme's bones, if the skeleton has every one of them (any letter case); else empty.
static func _by_name(skeleton: Skeleton3D, scheme: Dictionary) -> Dictionary[String, int]:
	var index_of := {}
	for i in skeleton.get_bone_count():
		index_of[skeleton.get_bone_name(i).to_lower()] = i
	var result: Dictionary[String, int] = {}
	for key: String in scheme:
		var bone: String = scheme[key]
		if not index_of.has(bone.to_lower()):
			return {}
		result[key] = index_of[bone.to_lower()]
	return result


## A collarbone is a short first piece next to the upper arm and forearm that follow it.
static func _is_collarbone(chain: Array[int], position: Array[Vector3]) -> bool:
	var first := position[chain[1]].distance_to(position[chain[0]])
	var upper := position[chain[2]].distance_to(position[chain[1]])
	var lower := position[chain[3]].distance_to(position[chain[2]])
	return first < COLLAR_SHARE * (upper + lower) * 0.5


## [upper arm, elbow, wrist] out of an arm chain that may hold extra joints: twist bones along
## the arm, and a run of short finger bones at the end. The wrist is where the last long
## segment ends, and the elbow is the joint nearest the middle of the arm.
static func _arm_joints(chain: Array[int], position: Array[Vector3]) -> Array[int]:
	var lengths: Array[float] = []
	var longest := 0.0
	for i in range(1, chain.size()):
		lengths.append(position[chain[i]].distance_to(position[chain[i - 1]]))
		longest = maxf(longest, lengths[i - 1])
	var wrist := 2
	for i in range(1, chain.size()):
		if lengths[i - 1] >= LONG_SEGMENT_SHARE * longest:
			wrist = i
	wrist = maxi(wrist, 2)
	var arm_length := 0.0
	for i in range(wrist):
		arm_length += lengths[i]
	var elbow := 1
	var walked := 0.0
	var nearest := INF
	for i in range(1, wrist):
		walked += lengths[i - 1]
		if absf(walked - arm_length * 0.5) < nearest:
			nearest = absf(walked - arm_length * 0.5)
			elbow = i
	return [chain[0], chain[elbow], chain[wrist]]


static func _subtree_size(bone: int, children: Array[PackedInt32Array]) -> int:
	var total := 1
	for child in children[bone]:
		total += _subtree_size(child, children)
	return total


static func _subtree_extreme(bone: int, children: Array[PackedInt32Array], position: Array[Vector3], lowest: bool) -> float:
	var value := position[bone].y
	for child in children[bone]:
		var other := _subtree_extreme(child, children, position, lowest)
		value = minf(value, other) if lowest else maxf(value, other)
	return value


static func _tallest_child(bone: int, children: Array[PackedInt32Array], position: Array[Vector3]) -> int:
	var best := -1
	var best_height := -INF
	for child in children[bone]:
		var reach := _subtree_extreme(child, children, position, false)
		if reach > best_height:
			best_height = reach
			best = child
	return best


## Follows a limb along its main branch: the child with the biggest subtree.
static func _chain(start: int, children: Array[PackedInt32Array]) -> Array[int]:
	var chain: Array[int] = []
	var at := start
	while at >= 0:
		chain.append(at)
		var next := -1
		var best := -1
		for child in children[at]:
			var size := _subtree_size(child, children)
			if size > best:
				best = size
				next = child
		at = next
	return chain


## Which way the character's left is. Feet point forward from heel to toes; left = up x forward.
static func _left_axis(legs: Array[int], children: Array[PackedInt32Array], position: Array[Vector3]) -> Vector3:
	var forward := Vector3.ZERO
	for leg in legs:
		var chain := _chain(leg, children)
		if chain.size() >= 3:
			var toes := _toes(chain[2], children, position)
			if toes >= 0:
				forward += position[toes] - position[chain[2]]
	forward.y = 0.0
	if forward.length() < 0.001:
		forward = Vector3.BACK  # glTF characters face +Z
	return Vector3.UP.cross(forward.normalized())


## The toe bone below a foot: the child reaching farthest out along the ground (a heel bone, if
## there is one, sits under the ankle instead). -1 if the foot has no children.
static func _toes(foot: int, children: Array[PackedInt32Array], position: Array[Vector3]) -> int:
	var best := -1
	var reach := 0.0
	for child in children[foot]:
		var offset := position[child] - position[foot]
		var flat := Vector2(offset.x, offset.z).length()
		if best < 0 or flat > reach:
			best = child
			reach = flat
	return best


## The two leg branches: leg-bearing branches below the hips, followed down while they are a single
## chain (a pelvis bone, say) until they split in two.
static func _split_legs(branches: Array[int], children: Array[PackedInt32Array], position: Array[Vector3], below: float) -> Array[int]:
	var candidates := branches.duplicate()
	while candidates.size() == 1:
		var next: Array[int] = []
		for child in children[candidates[0]]:
			if _subtree_extreme(child, children, position, true) < below:
				next.append(child)
		if next.is_empty():
			break
		candidates = next
	if candidates.size() > 2:  # keep the two that reach lowest (a tail or skirt bone would be shorter)
		candidates.sort_custom(func(a: int, b: int) -> bool: return _subtree_extreme(a, children, position, true) < _subtree_extreme(b, children, position, true))
		candidates = candidates.slice(0, 2)
	return candidates
