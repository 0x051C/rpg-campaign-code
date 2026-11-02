class_name TestRecorder
extends Node

## Records what you do in the game as a test, and plays it back (autoload GameTestRecorder).
##
## Recording: the Tests dock's Record button writes a request (REQUEST_PATH) and plays a map;
## this node finds the request when the game starts and records every key, mouse button and
## mouse move, stamped with the scene (map) it happened in and the physics frame since that
## scene started, plus the camera whenever it moved. F9 takes a checkpoint: a snapshot of the
## party (heroes, levels, health, positions), gold, items, quests, story flags and tutorial
## lesson. F10 takes a last checkpoint, saves tests/recordings/<name>.json and quits.
##
## Playback: started with the environment variable RECORDING=<file> (the test runner does
## that), it seeds the random numbers the same way, feeds the events back at the same physics
## frames with the same camera, and at each checkpoint compares the game against the snapshot
## within the recording's `tolerance` (edit it, or list keys under a checkpoint's "ignore").
## Prints "ok"/"FAIL" lines and "FAILURES: n" like every other test, then quits.

enum Mode { OFF, RECORDING, REPLAYING }

const REQUEST_PATH := "user://test_recording_request.json"
const VERSION := 1
const CHECKPOINT_KEY := KEY_F9
const STOP_KEY := KEY_F10
const AUTOSAVE_TIME := 10.0  ## seconds; stopping the game from the editor loses at most this much
const STALL_FRAMES := 60 * 120  ## playback gives up after 2 game minutes waiting for a scene
const DEFAULT_TOLERANCE := {"position": 2.0, "health": 0.25}

static var current: TestRecorder

var mode := Mode.OFF

var _data := {}  ## the recording: header, checkpoints, events
var _path := ""  ## where it's saved / read from
var _scene: Node
var _scene_index := -1
var _scene_start := 0
var _next_event := 0
var _next_checkpoint := 0
var _last_camera := []
var _flash_time := 0.0
var _autosave := AUTOSAVE_TIME
var _stall := 0
var _failures := 0
var _finished := false
var _overlay: Label  ## the REC / REPLAY line, made when needed


func _init() -> void:
	current = self


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = -1000  # feed events before the game thinks
	if not OS.is_debug_build():
		return
	if OS.has_environment("RECORDING"):
		_start_replay(OS.get_environment("RECORDING"))
	elif FileAccess.file_exists(REQUEST_PATH):
		var request: Variant = JSON.parse_string(FileAccess.get_file_as_string(REQUEST_PATH))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(REQUEST_PATH))
		if request is Dictionary:
			_start_recording(request)


## A recording file as a Dictionary; {} when it can't be read.
static func load_recording(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary and parsed.get("version", 0) == VERSION else {}


## Asks the next game start to record a test called `test_name` (the Tests dock calls this,
## then plays `map`).
static func request_recording(test_name: String, map: String) -> void:
	var file := FileAccess.open(REQUEST_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify({"name": test_name, "map": map}))


# --- Recording -----------------------------------------------------------------

func _start_recording(request: Dictionary) -> void:
	mode = Mode.RECORDING
	var test_name := String(request.get("name", "recording")).validate_filename()
	_path = "res://tests/recordings/%s.json" % test_name
	_data = {
		"version": VERSION,
		"name": test_name,
		"map": request.get("map", ProjectSettings.get_setting("application/run/main_scene")),
		"seed": absi(hash(test_name + str(Time.get_unix_time_from_system()))) % 1000000,
		"window": [get_window().size.x, get_window().size.y],
		"tolerance": DEFAULT_TOLERANCE.duplicate(),
		"checkpoints": [],
		"events": [],
	}
	seed(_data.seed)
	get_tree().root.window_input.connect(_on_window_input)
	_show_overlay()


func _on_window_input(event: InputEvent) -> void:
	if mode != Mode.RECORDING or _scene_index < 0:
		return
	var key := event as InputEventKey
	if key != null and key.keycode in [CHECKPOINT_KEY, STOP_KEY]:
		if key.pressed and not key.echo:
			if key.keycode == CHECKPOINT_KEY:
				_checkpoint("F9")
			else:
				_stop_recording()
		return
	var stamped := _encode(event)
	if stamped.is_empty():
		return
	stamped.s = _scene_index
	stamped.f = Engine.get_physics_frames() - _scene_start
	var events: Array = _data.events
	# Mouse moves within one physics frame: only the last one matters
	if stamped.t == "mot" and not events.is_empty():
		var last: Dictionary = events.back()
		if last.t == "mot" and last.s == stamped.s and last.f == stamped.f and last.get("bm", 0) == stamped.get("bm", 0):
			events.pop_back()
	var camera := _camera_state()
	if not camera.is_empty() and camera != _last_camera:
		stamped.c = camera
		_last_camera = camera
	events.append(stamped)


func _checkpoint(label: String) -> void:
	_data.checkpoints.append({"s": _scene_index, "f": Engine.get_physics_frames() - _scene_start, "label": label,
			"ignore": [], "state": snapshot()})
	_save()
	_flash("Checkpoint %d saved" % _data.checkpoints.size())


func _stop_recording() -> void:
	_checkpoint("end")
	mode = Mode.OFF
	print("Recorded %d events and %d checkpoints to %s" % [_data.events.size(), _data.checkpoints.size(), _path])
	get_tree().quit()


func _save() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_path.get_base_dir()))
	var file := FileAccess.open(ProjectSettings.globalize_path(_path), FileAccess.WRITE)
	if file == null:
		push_error("Can't write %s" % _path)
		return
	# One event per line: the file stays readable and diffs well
	var header := _data.duplicate()
	header.erase("checkpoints")
	header.erase("events")
	var text := JSON.stringify(header, "\t").trim_suffix("\n}") + ",\n"
	text += '\t"checkpoints": ' + JSON.stringify(_data.checkpoints, "\t").replace("\n", "\n\t") + ",\n"
	text += '\t"events": [\n'
	var lines := PackedStringArray()
	for event: Dictionary in _data.events:
		lines.append("\t\t" + JSON.stringify(event))
	text += ",\n".join(lines) + "\n\t]\n}\n"
	file.store_string(text)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and mode == Mode.RECORDING:
		_checkpoint("end")  # closing the window saves too


# --- Playback ------------------------------------------------------------------

func _start_replay(path: String) -> void:
	_data = load_recording(path)
	if _data.is_empty():
		print("FAIL can't read the recording %s" % path)
		print("FAILURES: 1")
		get_tree().quit(1)
		return
	mode = Mode.REPLAYING
	Campaign.save_dir = Campaign.TEST_SAVE_DIR  # what the replay saves stays out of the player's saves
	_path = path
	seed(int(_data.seed))
	var speed := float(OS.get_environment("SPEED")) if OS.has_environment("SPEED") else 1.0
	Engine.time_scale = speed
	Engine.physics_ticks_per_second = roundi(60.0 * speed)
	Engine.max_physics_steps_per_frame = maxi(8, roundi(speed * 1.5))
	_show_overlay()


func _physics_process(_delta: float) -> void:
	var scene := get_tree().current_scene
	if scene != null and scene != _scene and scene.is_inside_tree():
		_scene = scene
		_scene_index += 1
		_scene_start = Engine.get_physics_frames()
	if mode == Mode.REPLAYING and not _finished:
		_replay_step()


func _process(delta: float) -> void:
	if mode == Mode.RECORDING:
		_autosave -= delta
		if _autosave <= 0.0:
			_autosave = AUTOSAVE_TIME
			_save()
	_flash_time -= delta
	if _overlay != null and _scene_index >= 0 and _flash_time <= 0.0:
		var seconds := float(Engine.get_physics_frames() - _scene_start) / Engine.physics_ticks_per_second * Engine.time_scale
		_overlay.text = "%s  %s  scene %d · %ds" % ["● REC" if mode == Mode.RECORDING else "▶ REPLAY", _data.name,
				_scene_index, seconds]
		if mode == Mode.RECORDING:
			_overlay.text += "    F9 checkpoint · F10 stop and save"


func _replay_step() -> void:
	if _scene_index < 0:
		return
	var now := Engine.get_physics_frames() - _scene_start
	var events: Array = _data.events
	var checkpoints: Array = _data.checkpoints
	var progressed := false
	while _next_event < events.size() and _due(events[_next_event], now):
		var stamped: Dictionary = events[_next_event]
		if stamped.has("c"):
			var camera := scene_camera()
			if camera != null:
				camera.load_state({"position": Vector3(stamped.c[0], stamped.c[1], stamped.c[2]), "distance": stamped.c[3]})
		var event := _decode(stamped)
		if event != null:
			Input.parse_input_event(event)
		_next_event += 1
		progressed = true
	while _next_checkpoint < checkpoints.size() and _due(checkpoints[_next_checkpoint], now):
		_compare(checkpoints[_next_checkpoint], _next_checkpoint + 1)
		_next_checkpoint += 1
		progressed = true
	_stall = 0 if progressed else _stall + 1
	if _next_event >= events.size() and _next_checkpoint >= checkpoints.size():
		_end_replay()
	elif _stall > STALL_FRAMES:
		print("FAIL playback stalled in scene %d (the game went somewhere the recording didn't)" % _scene_index)
		_failures += 1
		_end_replay()


func _due(stamp: Dictionary, now: int) -> bool:
	return int(stamp.s) < _scene_index or (int(stamp.s) == _scene_index and int(stamp.f) <= now)


func _end_replay() -> void:
	_finished = true
	print("FAILURES: %d" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


# --- Checkpoints ---------------------------------------------------------------

## What a checkpoint records: the map, the party's heroes (name, level, alive, health and
## position), gold, the bag, story flags, quests on this map and the tutorial lesson.
func snapshot() -> Dictionary:
	var scene := get_tree().current_scene
	var state := {"map": scene.scene_file_path if scene != null else ""}
	if scene == null:
		return state
	var registry := scene.get_node_or_null(^"UnitRegistry") as UnitRegistry
	var commander := scene.get_node_or_null(^"Commander") as Commander
	if registry != null and commander != null:
		var heroes := []
		for handle in commander.heroes:
			var unit := registry.unit_of(handle)
			if unit != null:
				heroes.append({"name": unit.definition.display_name, "level": unit.level, "alive": unit.is_alive(),
						"health": roundi(registry.health_of(handle)), "x": snappedf(unit.global_position.x, 0.1),
						"z": snappedf(unit.global_position.z, 0.1)})
		state.heroes = heroes
	var party := scene.get_node_or_null(^"Party") as PartyInventory
	if party != null:
		state.gold = party.gold
		var bag := party.bag.map(func(item: ItemDefinition) -> String: return item.display_name)
		bag.sort()
		state.bag = bag
	if Campaign.current != null:
		var story: Array = Campaign.current.flags.get("story", {}).keys()
		story.sort()
		state.story = story
		var quests := {}
		for node in get_tree().get_nodes_in_group(Quest.GROUP):
			var quest := node as Quest
			quests[str(scene.get_path_to(quest))] = "done" if quest.done else (str(quest.current.name) if quest.current != null else "")
		state.quests = quests
	var tutorial := scene.get_node_or_null(^"Tutorial") as Tutorial
	if tutorial != null:
		state.tutorial = str(tutorial.current.name) if tutorial.current != null else ""
	return state


func _compare(checkpoint: Dictionary, number: int) -> void:
	var expected: Dictionary = checkpoint.state
	var actual := snapshot()
	var ignore: Array = checkpoint.get("ignore", [])
	var tolerance: Dictionary = _data.get("tolerance", DEFAULT_TOLERANCE)
	var problems := PackedStringArray()
	for key: String in expected:
		if ignore.has(key):
			continue
		if key == "heroes":
			problems.append_array(_compare_heroes(expected.heroes, actual.get("heroes", []), tolerance))
		elif expected[key] != actual.get(key):
			problems.append("%s is %s, expected %s" % [key, _text(actual.get(key)), _text(expected[key])])
	var what := "checkpoint %d (%s)" % [number, checkpoint.get("label", "")]
	if problems.is_empty():
		print("ok   %s" % what)
	else:
		_failures += 1
		print("FAIL %s: %s" % [what, "; ".join(problems)])


func _compare_heroes(expected: Array, actual: Array, tolerance: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	if expected.size() != actual.size():
		problems.append("%d heroes, expected %d" % [actual.size(), expected.size()])
		return problems
	for i in expected.size():
		var want: Dictionary = expected[i]
		var got: Dictionary = actual[i]
		for key in ["name", "level", "alive"]:
			if want[key] != got[key]:
				problems.append("%s %s is %s, expected %s" % [want.name, key, _text(got[key]), _text(want[key])])
		var slack := maxf(float(want.health) * float(tolerance.get("health", 0.25)), 20.0)
		if absf(float(got.health) - float(want.health)) > slack:
			problems.append("%s health %d, expected %d ± %d" % [want.name, int(got.health), int(want.health), int(slack)])
		var off := Vector2(float(got.x) - float(want.x), float(got.z) - float(want.z)).length()
		if off > float(tolerance.get("position", 2.0)):
			problems.append("%s is %.1f m from where it was" % [want.name, off])
	return problems


## Whole numbers read back from JSON as floats print as "2", not "2.0".
static func _text(value: Variant) -> String:
	if value is float and is_equal_approx(value, roundf(value)):
		return str(int(value))
	return JSON.stringify(value) if value is String or value is Array or value is Dictionary else str(value)


# --- Events and the camera ------------------------------------------------------

func scene_camera() -> RTSCamera:
	var scene := get_tree().current_scene
	return scene.get_node_or_null(^"RTSCamera") as RTSCamera if scene != null else null


func _camera_state() -> Array:
	var camera := scene_camera()
	if camera == null:
		return []
	return [snappedf(camera.position.x, 0.001), snappedf(camera.position.y, 0.001), snappedf(camera.position.z, 0.001),
			snappedf(camera.distance, 0.001)]


func _encode(event: InputEvent) -> Dictionary:
	var stamped := {}
	if event is InputEventKey:
		var key := event as InputEventKey
		stamped = {"t": "key", "k": key.keycode, "p": key.physical_keycode, "u": key.unicode, "d": key.pressed,
				"e": key.echo}
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		stamped = {"t": "btn", "b": button.button_index, "d": button.pressed, "x": button.position.x,
				"y": button.position.y, "dc": button.double_click, "fa": button.factor}
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		stamped = {"t": "mot", "x": motion.position.x, "y": motion.position.y, "rx": motion.relative.x,
				"ry": motion.relative.y}
		if motion.button_mask != 0:
			stamped.bm = motion.button_mask
	else:
		return {}
	var with_mods := event as InputEventWithModifiers
	var mods := (1 if with_mods.shift_pressed else 0) | (2 if with_mods.ctrl_pressed else 0) \
			| (4 if with_mods.alt_pressed else 0) | (8 if with_mods.meta_pressed else 0)
	if mods != 0:
		stamped.m = mods
	return stamped


func _decode(stamped: Dictionary) -> InputEvent:
	var event: InputEventWithModifiers
	match stamped.t:
		"key":
			var key := InputEventKey.new()
			key.keycode = int(stamped.k) as Key
			key.physical_keycode = int(stamped.p) as Key
			key.unicode = int(stamped.u)
			key.pressed = stamped.d
			key.echo = stamped.e
			event = key
		"btn":
			var button := InputEventMouseButton.new()
			button.button_index = int(stamped.b) as MouseButton
			button.pressed = stamped.d
			button.double_click = stamped.dc
			button.factor = float(stamped.get("fa", 1.0))
			button.position = Vector2(stamped.x, stamped.y)
			button.global_position = button.position
			event = button
		"mot":
			var motion := InputEventMouseMotion.new()
			motion.position = Vector2(stamped.x, stamped.y)
			motion.global_position = motion.position
			motion.relative = Vector2(stamped.rx, stamped.ry)
			motion.button_mask = int(stamped.get("bm", 0)) as MouseButtonMask
			event = motion
		_:
			return null
	var mods := int(stamped.get("m", 0))
	event.shift_pressed = mods & 1 != 0
	event.ctrl_pressed = mods & 2 != 0
	event.alt_pressed = mods & 4 != 0
	event.meta_pressed = mods & 8 != 0
	return event


func _show_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)
	_overlay = Label.new()
	_overlay.position = Vector2(12, 4)
	_overlay.add_theme_color_override(&"font_color", Color(1.0, 0.35, 0.3) if mode == Mode.RECORDING else Color(0.5, 0.9, 1.0))
	_overlay.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_overlay.add_theme_constant_override(&"outline_size", 4)
	layer.add_child(_overlay)


func _flash(text: String) -> void:
	if _overlay == null:
		return
	_overlay.text = text
	_flash_time = 1.5 * Engine.time_scale
