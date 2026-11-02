@tool
extends VBoxContainer

## The Tests dock (added to the editor by addons/test_suite). Lists every test of the test pass
## layout (tests/suite.cfg, see TestSuite) with a box to switch it off, the last run's result
## and a note; runs tests through tests/run_tests.gd in the background; and records new tests:
## Record plays a map while TestRecorder records your inputs (F9 checkpoint, F10 stop).

enum Column { ON, TEST, RESULT, NOTE }

const POLL_TIME := 0.5
const PASS_COLOR := Color(0.45, 0.9, 0.5)
const FAIL_COLOR := Color(1.0, 0.45, 0.4)
const SKIP_COLOR := Color(1, 1, 1, 0.45)

var _tree := Tree.new()
var _speed := SpinBox.new()
var _status := Label.new()
var _record_name := LineEdit.new()
var _record_map := OptionButton.new()
var _entries: Array[Dictionary] = []
var _results := {}
var _pid := -1
var _results_time := 0
var _recording := false
var _timer := Timer.new()


func _ready() -> void:
	var help := Button.new()
	help.text = "How do tests work? (CLAUDE.md, Tests)"
	help.flat = true
	help.pressed.connect(func() -> void: OS.shell_open(ProjectSettings.globalize_path("res://CLAUDE.md")))
	add_child(help)

	var run_row := HFlowContainer.new()
	run_row.add_child(_button("Run all", "Every enabled test", func() -> void: _run(PackedStringArray())))
	run_row.add_child(_button("Run selected", "The selected rows, even if switched off", _run_selected))
	run_row.add_child(_button("Run failed", "The tests that failed last time", _run_failed))
	run_row.add_child(_button("Stop", "Stop the run", _stop))
	_speed.min_value = 1
	_speed.max_value = 32
	_speed.value = TestSuite.DEFAULT_SPEED
	_speed.suffix = "x"
	_speed.tooltip_text = "Game speed for the run (1 = real time)"
	run_row.add_child(_speed)
	add_child(run_row)

	_tree.columns = 4
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_MULTI
	_tree.column_titles_visible = true
	for column: int in [Column.ON, Column.TEST, Column.RESULT, Column.NOTE]:
		_tree.set_column_title(column, ["On", "Test", "Last run", "Note (why it's off)"][column])
	_tree.set_column_expand(Column.ON, false)
	_tree.set_column_custom_minimum_width(Column.ON, 36)
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size.y = 260
	_tree.item_edited.connect(_on_edited)
	_tree.item_activated.connect(_on_activated)
	add_child(_tree)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.text = "Double-click a test to open its log."
	add_child(_status)

	add_child(HSeparator.new())
	var record_title := Label.new()
	record_title.text = "Record a test"
	add_child(record_title)
	_record_name.placeholder_text = "test name, e.g. bridge_ambush"
	add_child(_record_name)
	add_child(_record_map)
	add_child(_button("Record", "Plays the map and records what you do", _record))
	var record_help := Label.new()
	record_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	record_help.text = "Play as usual. F9 takes a checkpoint (heroes, gold, items, quests, tutorial); F10 takes the last one, saves tests/recordings/<name>.json and stops. The test replays your input and checks the checkpoints."
	record_help.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.6))
	add_child(record_help)

	_timer.wait_time = POLL_TIME
	_timer.timeout.connect(_poll)
	add_child(_timer)
	_timer.start()
	_fill_maps()
	refresh()


## Reloads suite.cfg, the recordings and the last results.
func refresh() -> void:
	_entries = TestSuite.entries()
	_results = TestSuite.last_results()
	_tree.clear()
	var root := _tree.create_item()
	for entry in _entries:
		var item := _tree.create_item(root)
		item.set_cell_mode(Column.ON, TreeItem.CELL_MODE_CHECK)
		item.set_editable(Column.ON, true)
		item.set_checked(Column.ON, entry.enabled)
		item.set_text(Column.TEST, entry.id)
		item.set_tooltip_text(Column.TEST, entry.script if not entry.script.is_empty() else entry.recording)
		item.set_editable(Column.NOTE, true)
		item.set_text(Column.NOTE, entry.note)
		item.set_metadata(0, entry.id)
		_show_result(item, _results.get(entry.id, {}))


func _show_result(item: TreeItem, result: Dictionary) -> void:
	match result.get("result", ""):
		"pass":
			item.set_text(Column.RESULT, "pass  %.1fs" % result.seconds)
			item.set_custom_color(Column.RESULT, PASS_COLOR)
		"fail":
			item.set_text(Column.RESULT, "FAIL  " + result.get("summary", ""))
			item.set_custom_color(Column.RESULT, FAIL_COLOR)
		"skipped":
			item.set_text(Column.RESULT, "skipped")
			item.set_custom_color(Column.RESULT, SKIP_COLOR)
		_:
			item.set_text(Column.RESULT, "not run")
			item.set_custom_color(Column.RESULT, SKIP_COLOR)
	item.set_tooltip_text(Column.RESULT, "\n".join(result.get("failed_checks", [])))


func _on_edited() -> void:
	var item := _tree.get_edited()
	var entry := _entry(item.get_metadata(0))
	entry.enabled = item.is_checked(Column.ON)
	entry.note = item.get_text(Column.NOTE)
	TestSuite.save(_entries)


func _on_activated() -> void:
	var item := _tree.get_selected()
	var log_path: String = _results.get(item.get_metadata(0), {}).get("log", "")
	if not log_path.is_empty() and FileAccess.file_exists(log_path):
		OS.shell_open(log_path)
	else:
		_status.text = "No log yet: run it first."


func _run(ids: PackedStringArray) -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		_status.text = "A run is going on; Stop it first."
		return
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script",
			"res://tests/run_tests.gd", "--", "--speed", str(_speed.value)])
	args.append_array(ids)
	_pid = OS.create_process(OS.get_executable_path(), args)
	_status.text = "Running %s… (each test opens a game window)" % ("all enabled tests" if ids.is_empty() else ", ".join(ids))


func _run_selected() -> void:
	var ids := PackedStringArray()
	var item := _tree.get_next_selected(null)
	while item != null:
		ids.append(item.get_metadata(0))
		item = _tree.get_next_selected(item)
	if ids.is_empty():
		_status.text = "Select tests first (Ctrl+click for several)."
	else:
		_run(ids)


func _run_failed() -> void:
	var ids := PackedStringArray()
	for id: String in _results:
		if _results[id].get("result", "") == "fail":
			ids.append(id)
	if ids.is_empty():
		_status.text = "Nothing failed last time."
	else:
		_run(ids)


func _stop() -> void:
	if _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
		_status.text = "Stopped (a test window that was open finishes on its own)."


func _poll() -> void:
	var stamp := FileAccess.get_modified_time(TestSuite.RESULTS_PATH) if FileAccess.file_exists(TestSuite.RESULTS_PATH) else 0
	if stamp != _results_time:
		_results_time = stamp
		_results = TestSuite.last_results()
		var item := _tree.get_root().get_first_child() if _tree.get_root() != null else null
		while item != null:
			_show_result(item, _results.get(item.get_metadata(0), {}))
			item = item.get_next()
	if _pid > 0 and not OS.is_process_running(_pid):
		_pid = -1
		var passed := 0
		var failed := 0
		for id: String in _results:
			passed += 1 if _results[id].get("result", "") == "pass" else 0
			failed += 1 if _results[id].get("result", "") == "fail" else 0
		_status.text = "Done: %d passed, %d failed. Double-click a test to open its log." % [passed, failed]
	if _recording and not EditorInterface.is_playing_scene():
		_recording = false
		refresh()
		_status.text = "Recording finished; it's in the list as recorded/%s." % _record_name.text.validate_filename()


func _record() -> void:
	var test_name := _record_name.text.strip_edges().validate_filename()
	if test_name.is_empty():
		_status.text = "Give the test a name first."
		return
	var map: String = _record_map.get_item_metadata(_record_map.selected)
	TestRecorder.request_recording(test_name, map)
	EditorInterface.play_custom_scene(map)
	_recording = true
	_status.text = "Recording %s: F9 checkpoint, F10 stop and save." % test_name


func _fill_maps() -> void:
	var maps := PackedStringArray()
	for directory in ["res://scenes/maps", "res://scenes"]:
		for file in DirAccess.get_files_at(directory):
			if file.ends_with(".tscn") and (directory == "res://scenes/maps" or file == "main.tscn"):
				maps.append(directory.path_join(file))
	maps.append(ProjectSettings.get_setting("application/run/main_scene"))
	for map in maps:
		_record_map.add_item(map.get_file().get_basename() + ("  (title screen)" if map == maps[-1] else ""))
		_record_map.set_item_metadata(_record_map.item_count - 1, map)
	_record_map.selected = maxi(maps.find(Campaign.FIRST_MAP), 0)


func _entry(id: String) -> Dictionary:
	for entry in _entries:
		if entry.id == id:
			return entry
	return {}


static func _button(text: String, tooltip: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.pressed.connect(on_pressed)
	return button
