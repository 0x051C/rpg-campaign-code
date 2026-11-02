@tool
class_name TestSuite
extends RefCounted

## The test pass layout: which tests exist, which are switched on, and why one is off.
## It lives in tests/suite.cfg, one section per test:
##
##     [items]
##     script="res://tests/test_items.gd"   ; a scripted test (a SceneTree script)
##     env={"PARTY": "knight mage"}         ; environment variables it reads (optional)
##     enabled=true                         ; false: the runner skips it
##     note=""                              ; why it's off, for whoever reads this later
##
##     [recorded/bridge_fight]
##     recording="res://tests/recordings/bridge_fight.json"   ; a recorded test (TestRecorder)
##
## tests/test_*.gd scripts and tests/recordings/*.json that suite.cfg doesn't list yet count as
## enabled tests; the Tests dock writes them into the file the first time you change anything.
## (The helpers in tests/framework/ aren't tests.)

const SUITE_PATH := "res://tests/suite.cfg"
const TESTS_DIR := "res://tests"
const RECORDINGS_DIR := "res://tests/recordings"
const OUTPUT_DIR := "res://tests/output"
const RESULTS_PATH := "res://tests/output/results.json"
const DEFAULT_SPEED := 16.0
const TIMEOUT := 300.0  ## seconds a test may run before the runner stops it


## Every test: suite.cfg's entries in order, then the unlisted ones found on disk.
## Each is {id, script, recording, env, enabled, note}.
static func entries() -> Array[Dictionary]:
	var list: Array[Dictionary] = []
	var config := ConfigFile.new()
	config.load(SUITE_PATH)
	var known := {}
	for id in config.get_sections():
		var entry := {
			"id": id,
			"script": config.get_value(id, "script", ""),
			"recording": config.get_value(id, "recording", ""),
			"env": config.get_value(id, "env", {}),
			"enabled": config.get_value(id, "enabled", true),
			"note": config.get_value(id, "note", ""),
		}
		list.append(entry)
		known[entry.script if not entry.script.is_empty() else entry.recording] = true
	for file in _files(TESTS_DIR, "test_", ".gd"):
		var path := TESTS_DIR.path_join(file)
		if not known.has(path):
			list.append({"id": file.get_basename().trim_prefix("test_"), "script": path, "recording": "", "env": {},
					"enabled": true, "note": ""})
	for file in _files(RECORDINGS_DIR, "", ".json"):
		var path := RECORDINGS_DIR.path_join(file)
		if not known.has(path):
			list.append({"id": "recorded/" + file.get_basename(), "script": "", "recording": path, "env": {},
					"enabled": true, "note": ""})
	return list


## Writes `list` to suite.cfg (comments in the file are not kept).
static func save(list: Array[Dictionary]) -> Error:
	var config := ConfigFile.new()
	for entry in list:
		if not entry.script.is_empty():
			config.set_value(entry.id, "script", entry.script)
		else:
			config.set_value(entry.id, "recording", entry.recording)
		if not entry.env.is_empty():
			config.set_value(entry.id, "env", entry.env)
		config.set_value(entry.id, "enabled", entry.enabled)
		config.set_value(entry.id, "note", entry.note)
	return config.save(SUITE_PATH)


## How to start `entry` as its own game process: {args, env}. A scripted test runs its
## SceneTree script; a recorded test starts its map like the editor's Play button, with
## RECORDING telling TestRecorder to replay it.
static func command(entry: Dictionary, speed: float) -> Dictionary:
	var project := ProjectSettings.globalize_path("res://")
	var output := ProjectSettings.globalize_path(OUTPUT_DIR)
	var env := {"SPEED": str(speed), "OUTPUT": output, "OUT": output.path_join(safe_name(entry.id))}
	env.merge(entry.env, true)
	var args := PackedStringArray(["--audio-driver", "Dummy", "--path", project])
	if not entry.script.is_empty():
		args.append_array(["--resolution", "1600x900", "--script", entry.script])
	else:
		var recording := TestRecorder.load_recording(entry.recording)
		if recording.is_empty():
			return {}
		env.RECORDING = ProjectSettings.globalize_path(entry.recording)
		args.append_array(["--resolution", "%dx%d" % [recording.window[0], recording.window[1]], recording.map])
	return {"args": args, "env": env}


## The results of the last run, by test id: {result, seconds, failures, log}.
static func last_results() -> Dictionary:
	if not FileAccess.file_exists(RESULTS_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RESULTS_PATH))
	return parsed if parsed is Dictionary else {}


static func safe_name(id: String) -> String:
	return id.replace("/", "_").replace(" ", "_").replace(":", "_")


static func _files(directory: String, prefix: String, suffix: String) -> PackedStringArray:
	var found := PackedStringArray()
	for file in DirAccess.get_files_at(directory):
		if file.begins_with(prefix) and file.ends_with(suffix):
			found.append(file)
	found.sort()
	return found
