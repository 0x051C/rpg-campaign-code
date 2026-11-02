class_name RTSCamera
extends Node3D

## Commander camera ported from noh's CPlayer, cam_mode 0
## (PrepareClientSnapshot / SetupCamera / StartDrag in src/hon_shared/c_player.cpp):
## arrow-key and screen-edge scrolling scaled by zoom, middle-mouse grab dragging,
## stepped wheel zoom, noh's weighted FOV, and map constraints that keep the whole
## view inside the camera bounds. This node sits on the look-at point on the ground.

const NOH_UNITS_PER_METER := 48.0  ## noh hero bounds radius (24 units) ~ a 0.5 m KayKit character

@export_group("Scrolling")
@export var edge_scroll := true  ## cam_edgeScroll
@export var edge_scroll_margin := 2.0  ## pixels; noh only scrolls on the outermost pixel
@export var scroll_speed := 3000.0 / NOH_UNITS_PER_METER  ## cam_scrollSpeed, at maximum zoom
@export var confine_mouse := false  ## keep the cursor inside the window so edge scrolling always works

@export_group("Zoom")
@export var distance_default := 1650.0 / NOH_UNITS_PER_METER  ## g_camDistanceDefault
@export var distance_min := 600.0 / NOH_UNITS_PER_METER  ## g_camDistanceMin
@export var distance_max := 1650.0 / NOH_UNITS_PER_METER  ## g_camDistanceMax
@export var distance_step := 80.0 / NOH_UNITS_PER_METER  ## cam_distanceStep
@export var zoom_smoothing := 14.0  ## 0 snaps instantly like noh

@export_group("View")
@export_range(-89.0, -1.0) var pitch := -56.0  ## g_camPitch
@export var yaw := 0.0  ## g_camYaw
@export var fov_x := 53.75  ## g_camFov, horizontal at fov_aspect
@export var fov_aspect := 1.515  ## g_camAspect
@export var fov_weight_x := 1.0  ## g_camWeightX
@export var fov_weight_y := 3.0  ## g_camWeightY

@export_group("Bounds")
@export var map_constraints := true  ## cam_mapConstraints
@export var bounds := Rect2(-80.0, -80.0, 160.0, 160.0)  ## XZ area the view must stay inside
@export var bounds_margin := 128.0 / NOH_UNITS_PER_METER

var distance := 0.0
## Screen edge the cursor is scrolling against, for cursor feedback.
var edge_scroll_direction := Vector2i.ZERO

var _shown_distance := 0.0
var _half_tan_x := 0.5
var _half_tan_y := 0.5
var _mouse_position := Vector2.ZERO
var _mouse_inside := false
var _dragging := false
var _drag_start_target := Vector3.ZERO
var _drag_start_world := Vector3.ZERO
var _drag_plane := Plane()
var _drag_camera := Transform3D()

@onready var camera: Camera3D = $Camera3D
## Where the world is heard from (DIRECTION.md 8): not the camera 30 m up, where everything on screen
## sounds alike, but a few meters above the ground it looks at, turned with the view, so sounds pan
## left and right and fade towards the screen's edges.
var listener := AudioListener3D.new()
const LISTENER_HEIGHT := 6.0


func _ready() -> void:
	distance = distance_default
	_shown_distance = distance
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	add_child(listener)
	listener.make_current()
	if confine_mouse:
		Input.mouse_mode = Input.MOUSE_MODE_CONFINED
	_update_fov()
	_apply_transform()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_EXIT:
		_mouse_inside = false


func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_mouse_position = event.position
	if event is InputEventMouseMotion:
		_mouse_inside = true
	elif event.is_action_released(&"rts_camera_drag"):
		_dragging = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"rts_zoom_in"):
		zoom(-1)
	elif event.is_action_pressed(&"rts_zoom_out"):
		zoom(1)
	elif event.is_action_pressed(&"rts_camera_drag"):
		_start_drag(event.position)
	elif event.is_action_pressed(&"rts_camera_reset"):
		reset()
	else:
		return
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_update_fov()

	var scroll := _scroll_input()
	if scroll != Vector2.ZERO:
		var direction := Basis(Vector3.UP, deg_to_rad(yaw)) * Vector3(scroll.x, 0.0, scroll.y).normalized()
		position += direction * scroll_speed * delta * (distance / distance_max)

	if _dragging:
		_update_drag()

	if zoom_smoothing <= 0.0:
		_shown_distance = distance
	else:
		_shown_distance = lerpf(_shown_distance, distance, 1.0 - exp(-zoom_smoothing * delta))

	if map_constraints:
		_constrain_to_bounds()
	_apply_transform()


## Zooms by whole wheel steps; positive steps move away from the ground.
func zoom(steps: int) -> void:
	distance = clampf(distance + steps * distance_step, distance_min, distance_max)


func save_state() -> Dictionary:
	return {"position": position, "distance": distance}


func load_state(data: Dictionary) -> void:
	position = data.position
	distance = data.distance
	_shown_distance = distance


## noh ResetCamera
func reset() -> void:
	distance = distance_default


func center_on(world_position: Vector3) -> void:
	position.x = world_position.x
	position.z = world_position.z


func is_dragging() -> bool:
	return _dragging


func _scroll_input() -> Vector2:
	var scroll := Vector2(
		Input.get_axis(&"rts_camera_left", &"rts_camera_right"),
		Input.get_axis(&"rts_camera_forward", &"rts_camera_back"))

	edge_scroll_direction = Vector2i.ZERO
	if edge_scroll and not _dragging and _mouse_inside and DisplayServer.window_is_focused():
		var mouse := _mouse_position
		var size := get_viewport().get_visible_rect().size
		if mouse.x <= edge_scroll_margin:
			edge_scroll_direction.x = -1
		elif mouse.x >= size.x - 1.0 - edge_scroll_margin:
			edge_scroll_direction.x = 1
		if mouse.y <= edge_scroll_margin:
			edge_scroll_direction.y = -1
		elif mouse.y >= size.y - 1.0 - edge_scroll_margin:
			edge_scroll_direction.y = 1

	return (scroll + Vector2(edge_scroll_direction)).clamp(-Vector2.ONE, Vector2.ONE)


## Grabs the ground point under the cursor; it then stays under the cursor while dragging.
func _start_drag(screen_position: Vector2) -> void:
	var hit := Terrain.trace(camera.project_ray_origin(screen_position), camera.project_ray_normal(screen_position))
	if hit == Vector3.INF:
		return
	_dragging = true
	_drag_start_target = position
	_drag_start_world = hit
	_drag_plane = Plane(Vector3.UP, hit)
	_drag_camera = camera.global_transform


func _update_drag() -> void:
	# Cast through the camera as it was when the drag started, like noh's m_cDragCamera
	var local_direction := camera.global_basis.inverse() * camera.project_ray_normal(_mouse_position)
	var hit = _drag_plane.intersects_ray(_drag_camera.origin, _drag_camera.basis * local_direction)
	if hit == null:
		return
	position.x = _drag_start_target.x - hit.x + _drag_start_world.x
	position.z = _drag_start_target.z - hit.z + _drag_start_world.z


## noh CCamera::SetFovFromAspect: keeps roughly the same playable area at any aspect
## ratio, weighted towards preserving the vertical extent.
func _update_fov() -> void:
	var size := get_viewport().get_visible_rect().size
	var aspect := size.x / maxf(size.y, 1.0)
	var standard_x := 2.0 * tan(deg_to_rad(fov_x * 0.5))
	var standard_y := standard_x / fov_aspect
	var weight_x := fov_weight_x / (fov_weight_x + fov_weight_y)
	var weight_y := fov_weight_y / (fov_weight_x + fov_weight_y)
	var extent_y := pow(standard_x / aspect, weight_x) * pow(standard_y, weight_y)
	_half_tan_y = extent_y * 0.5
	_half_tan_x = extent_y * aspect * 0.5
	camera.fov = rad_to_deg(atan(_half_tan_y)) * 2.0


func _view_basis() -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0))


func _apply_transform() -> void:
	var view := _view_basis()
	camera.global_transform = Transform3D(view, global_position + view.z * _shown_distance)
	var ground := Terrain.ground(global_position.x, global_position.z)
	listener.global_transform = Transform3D(Basis(Vector3.UP, atan2(-view.z.x, -view.z.z) + PI),
			Vector3(global_position.x, ground + LISTENER_HEIGHT, global_position.z))


func _constrain_to_bounds() -> void:
	var footprint := _view_footprint(_shown_distance)
	position.x = _clamp_axis(position.x,
		bounds.position.x - footprint.position.x + bounds_margin,
		bounds.end.x - footprint.end.x - bounds_margin)
	position.z = _clamp_axis(position.z,
		bounds.position.y - footprint.position.y + bounds_margin,
		bounds.end.y - footprint.end.y - bounds_margin)


## Ground area seen by the camera, relative to the look-at point. As in noh, corner
## rays are cut off at 2500 units so a view near the horizon stays finite.
func _view_footprint(view_distance: float) -> Rect2:
	var view := _view_basis()
	var origin := view.z * view_distance
	var max_length := 2500.0 / NOH_UNITS_PER_METER
	var footprint := Rect2()
	var first := true
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var direction := view * Vector3(sx * _half_tan_x, sy * _half_tan_y, -1.0)
			var length := max_length / direction.length()
			if direction.y < 0.0:
				length = minf(length, -origin.y / direction.y)
			var point := origin + direction * length
			var corner := Vector2(point.x, point.z)
			footprint = Rect2(corner, Vector2.ZERO) if first else footprint.expand(corner)
			first = false
	return footprint


static func _clamp_axis(value: float, low: float, high: float) -> float:
	if low > high:
		return (low + high) * 0.5
	return clampf(value, low, high)
