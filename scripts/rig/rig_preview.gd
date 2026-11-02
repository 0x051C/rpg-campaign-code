extends Node3D

## Test bench for generated characters. Drop a rigged .glb on the window (or pass
## `-- --rig=/path/model.glb`) and the KayKit animations play on it: the bones are found
## automatically (HumanoidMapper) and the motion is carried over (RigRetargeter).
##
## Left-drag orbits, wheel zooms, Space pauses. It cycles through every animation; pick one in the
## list to stay on it, tick "Cycle all" to resume. Esc closes the window.

const ANIMATION_FILES: Array[String] = [
	"res://assets/animations/Rig_Medium_General.glb",
	"res://assets/animations/Rig_Medium_MovementBasic.glb",
]
const T_POSE := "T-Pose"
const DEFAULT_ANIMATION := "Idle_A"
const CYCLE_MIN_SECONDS := 2.5  ## short animations repeat until at least this long has passed

var _player: AnimationPlayer
var _source: Skeleton3D
var _model: Node3D
var _target: Skeleton3D
var _retargeter: RigRetargeter
var _status: Label
var _list: ItemList
var _pivot := Node3D.new()
var _camera := Camera3D.new()
var _distance := 4.0
var _paused := false
var _cycle: CheckBox
var _cycle_left := 0.0


func _ready() -> void:
	_build_stage()
	_load_animations()
	get_window().files_dropped.connect(_on_files_dropped)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--rig="):
			load_rig(argument.trim_prefix("--rig="))


func _build_stage() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.27, 0.3, 0.35)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.5
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	sun.shadow_enabled = true
	add_child(sun)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20.0, 20.0)
	floor_mesh.mesh = plane
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.2, 0.22, 0.25)
	floor_mesh.material_override = material
	add_child(floor_mesh)
	add_child(_pivot)
	_pivot.add_child(_camera)
	_camera.fov = 40.0
	_update_camera()

	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := VBoxContainer.new()
	panel.position = Vector2(12.0, 12.0)
	layer.add_child(panel)
	_status = Label.new()
	_status.text = "Drop a rigged .glb on this window"
	panel.add_child(_status)
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(190.0, 420.0)
	_list.item_selected.connect(_on_animation_selected)
	panel.add_child(_list)
	_cycle = CheckBox.new()
	_cycle.text = "Cycle all"
	_cycle.button_pressed = true
	_cycle.toggled.connect(func(on: bool) -> void: _cycle_left = 0.0 if on else _cycle_left)
	panel.add_child(_cycle)
	var help := Label.new()
	help.text = "Drag: orbit · Wheel: zoom\nSpace: pause · Esc: close"
	panel.add_child(help)


func _load_animations() -> void:
	var animation_root := Node3D.new()
	add_child(animation_root)
	animation_root.visible = false  # only its skeleton is used, as the motion source
	for index in ANIMATION_FILES.size():
		var state := GLTFState.new()
		var document := GLTFDocument.new()
		if document.append_from_file(ProjectSettings.globalize_path(ANIMATION_FILES[index]), state) != OK:
			push_error("cannot load " + ANIMATION_FILES[index])
			continue
		var scene: Node = document.generate_scene(state)
		var found: AnimationPlayer = scene.find_children("*", "AnimationPlayer", true, false)[0]
		if index == 0:
			animation_root.add_child(scene)
			_player = found
			_source = scene.find_children("*", "Skeleton3D", true, false)[0]
		else:
			var library := _player.get_animation_library(&"")
			for animation in found.get_animation_list():
				if not library.has_animation(animation):
					library.add_animation(animation, found.get_animation(animation).duplicate())
			scene.free()
	for animation in _player.get_animation_list():
		if animation != T_POSE and not animation.ends_with("_Pose"):
			_list.add_item(animation)
	_player.play(T_POSE)
	_player.seek(0.0, true)
	_player.pause()


func _on_files_dropped(files: PackedStringArray) -> void:
	for file in files:
		if file.get_extension().to_lower() in ["glb", "gltf"]:
			load_rig(file)
			return


## Loads a rigged model and starts the selected animation on it.
func load_rig(path: String) -> void:
	if _model != null:
		_model.queue_free()
		_model = null
	var state := GLTFState.new()
	var document := GLTFDocument.new()
	if document.append_from_file(path, state) != OK:
		_status.text = "Cannot read " + path.get_file()
		return
	_model = document.generate_scene(state)
	add_child(_model)
	var skeletons := _model.find_children("*", "Skeleton3D", true, false)
	if skeletons.is_empty():
		_status.text = path.get_file() + " has no skeleton: rig it first"
		return
	_target = skeletons[0]
	_player.play(T_POSE)
	_player.seek(0.0, true)
	_player.pause()
	_retargeter = RigRetargeter.new()
	if not _retargeter.setup(_source, _target, _player):
		_status.text = "%s: no humanoid found (%d bones)" % [path.get_file(), _target.get_bone_count()]
		_retargeter = null
		return
	_status.text = "%s: %d of %d bones are humanoid%s" % [path.get_file(), _retargeter.mapping.size(), _target.get_bone_count(), " (A-pose arms)" if _retargeter.arms_from_idle else ""]
	_frame_model()
	var wanted := DEFAULT_ANIMATION
	for i in _list.item_count:
		if _list.get_item_text(i) == wanted:
			_list.select(i)
	_play(wanted)


func _frame_model() -> void:
	var low := Vector3(INF, INF, INF)
	var high := Vector3(-INF, -INF, -INF)
	for i in _target.get_bone_count():
		var point := _target.global_transform * _target.get_bone_global_rest(i).origin
		low = low.min(point)
		high = high.max(point)
	_pivot.position = Vector3(0.0, (low.y + high.y) * 0.5, 0.0)
	_distance = maxf((high.y - low.y) * 2.6, 1.5)
	_update_camera()


func _play(animation: String) -> void:
	_player.play(animation)
	var clip := _player.get_animation(animation)
	clip.loop_mode = Animation.LOOP_LINEAR
	_paused = false
	_cycle_left = clip.length * ceilf(CYCLE_MIN_SECONDS / maxf(clip.length, 0.01))
	for i in _list.item_count:
		if _list.get_item_text(i) == animation:
			_list.select(i)
			_list.ensure_current_is_visible()


func _on_animation_selected(index: int) -> void:
	_cycle.button_pressed = false  # a hand-picked animation stays on
	_play(_list.get_item_text(index))


func _process(delta: float) -> void:
	if _retargeter == null:
		return
	if _cycle.button_pressed and not _paused:
		_cycle_left -= delta
		if _cycle_left <= 0.0:
			var selected := _list.get_selected_items()
			var next := (selected[0] + 1) % _list.item_count if not selected.is_empty() else 0
			_play(_list.get_item_text(next))
	_retargeter.apply()  # after the animation player has posed the source


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_pivot.rotate_y(-event.relative.x * 0.008)
		_pivot.rotation.x = clampf(_pivot.rotation.x - event.relative.y * 0.008, -1.2, 1.2)
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_distance = maxf(_distance * 0.9, 0.5)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_distance = minf(_distance * 1.1, 40.0)
		_update_camera()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().quit()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
		_paused = not _paused
		if _paused:
			_player.pause()
		else:
			_player.play(_player.current_animation)


func _update_camera() -> void:
	_camera.position = Vector3(0.0, 0.0, _distance)
