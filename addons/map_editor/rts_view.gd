@tool
extends RefCounted

## RTS navigation for one of the editor's 3D views, instead of the fly-around
## camera: the view looks down at the map like the game camera does. Wheel zooms
## towards the cursor, middle-drag grabs the ground, right-drag turns and tilts,
## arrow keys pan (Shift for faster), F centers on the selection. Left clicks,
## gizmos and the editor's shortcuts are left alone.

const PITCH := -56.0  ## RTSCamera.pitch, the game's view
const DISTANCE_DEFAULT := 1650.0 / RTSCamera.NOH_UNITS_PER_METER  ## RTSCamera.distance_default
const PITCH_MIN := -89.0
const PITCH_MAX := -20.0
const DISTANCE_MIN := 3.0
const DISTANCE_MAX := 250.0
const ZOOM_STEP := 1.15
const PAN_SPEED := 1.0  ## view distances per second
const TURN_SPEED := 0.25  ## degrees per pixel
const ARROWS: Dictionary[Key, Vector2] = {KEY_LEFT: Vector2.LEFT, KEY_RIGHT: Vector2.RIGHT, KEY_UP: Vector2.UP, KEY_DOWN: Vector2.DOWN}

var focus := Vector3.ZERO  ## ground point at the center of the view
var distance := DISTANCE_DEFAULT
var yaw := 0.0
var pitch := PITCH

var _grab := Vector3.INF  ## ground point held under the cursor while middle-dragging
var _turning := false
var _held: Dictionary[Key, bool] = {}


## Starts from wherever the editor camera looks now, at the game's angle and zoom.
func take_over(camera: Camera3D) -> void:
	var forward := -camera.global_basis.z
	var hit: Variant = _ground_plane().intersects_ray(camera.global_position, forward)
	if hit == null:
		hit = Vector3(camera.global_position.x, MapProp.GROUND_HEIGHT, camera.global_position.z)
	focus = hit
	distance = DISTANCE_DEFAULT
	if Vector2(forward.x, forward.z).length() > 0.01:
		yaw = rad_to_deg(atan2(-forward.x, -forward.z))
	pitch = PITCH


func get_state() -> Dictionary:
	return {&"focus": focus, &"distance": distance, &"yaw": yaw, &"pitch": pitch}


func set_state(state: Dictionary) -> void:
	focus = state.get(&"focus", focus)
	distance = state.get(&"distance", distance)
	yaw = state.get(&"yaw", yaw)
	pitch = state.get(&"pitch", pitch)


func apply(camera: Camera3D) -> void:
	var view := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0))
	var wanted := Transform3D(view, focus + view.z * distance)
	if not camera.global_transform.is_equal_approx(wanted):
		camera.global_transform = wanted


## Pans with the held arrow keys.
func process(camera: Camera3D, delta: float) -> void:
	var direction := Vector2.ZERO
	for key: Key in _held:
		if _held[key] and Input.is_physical_key_pressed(key):
			direction += ARROWS[key]
		else:
			_held[key] = false  # released while another control had focus
	if direction == Vector2.ZERO:
		return
	var speed := PAN_SPEED * distance * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	var step := Vector3(direction.x, 0.0, direction.y).normalized().rotated(Vector3.UP, deg_to_rad(yaw)) * speed * delta
	focus += step
	apply(camera)


## Returns true when the event was a camera control, so the editor ignores it.
func handle(camera: Camera3D, event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					var steps := button.factor if button.factor > 0.0 else 1.0
					var zoom := pow(ZOOM_STEP, steps if button.button_index == MOUSE_BUTTON_WHEEL_DOWN else -steps)
					_zoom(camera, _view_point(camera, button.position), zoom)
				return true
			MOUSE_BUTTON_MIDDLE:
				_grab = Vector3.INF
				if button.pressed:
					var hit: Variant = _ground_under(camera, _view_point(camera, button.position))
					if hit != null:
						_grab = hit
				return true
			MOUSE_BUTTON_RIGHT:
				_turning = button.pressed
				return true
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _grab != Vector3.INF:
			if not motion.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
				_grab = Vector3.INF  # released outside the view
				return false
			var hit: Variant = _ground_under(camera, _view_point(camera, motion.position))
			if hit != null:
				focus += _grab - (hit as Vector3)
				apply(camera)
			return true
		if _turning:
			if not motion.button_mask & MOUSE_BUTTON_MASK_RIGHT:
				_turning = false
				return false
			yaw -= motion.relative.x * TURN_SPEED
			pitch = clampf(pitch - motion.relative.y * TURN_SPEED, PITCH_MIN, PITCH_MAX)
			apply(camera)
			return true
	elif event is InputEventKey:
		var key := event as InputEventKey
		if ARROWS.has(key.physical_keycode) and not key.ctrl_pressed and not key.alt_pressed:
			_held[key.physical_keycode] = key.pressed
			return true
	return false


## Centers the view on a world point, keeping zoom and angle.
func center_on(point: Vector3, camera: Camera3D) -> void:
	focus = Vector3(point.x, MapProp.GROUND_HEIGHT, point.z)
	apply(camera)


## Keeps the ground point under the cursor fixed while changing the distance.
func _zoom(camera: Camera3D, at: Vector2, factor: float) -> void:
	var before: Variant = _ground_under(camera, at)
	distance = clampf(distance * factor, DISTANCE_MIN, DISTANCE_MAX)
	apply(camera)
	var after: Variant = _ground_under(camera, at)
	if before != null and after != null:
		focus += (before as Vector3) - (after as Vector3)
		apply(camera)


## Forwarded events are in the view's control space; the camera renders into a
## SubViewport that may be smaller (half resolution).
static func _view_point(camera: Camera3D, position: Vector2) -> Vector2:
	var container := camera.get_viewport().get_parent() as SubViewportContainer
	return position / float(container.stretch_shrink) if container != null else position


static func _ground_under(camera: Camera3D, at: Vector2) -> Variant:
	var hit := Terrain.trace(camera.project_ray_origin(at), camera.project_ray_normal(at))
	return hit if hit != Vector3.INF else null


static func _ground_plane() -> Plane:
	return Plane(Vector3.UP, MapProp.GROUND_HEIGHT)
