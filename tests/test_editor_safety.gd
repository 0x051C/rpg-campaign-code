extends SceneTree
## Guards against a Godot 4.7 editor data loss: on a script without @tool, an exported packed array
## whose default is an Array literal (`@export var lines: PackedStringArray = []`) loads empty in the
## editor, and the next save of the scene wipes it (it cost the prologue all its dialogue once). Default
## packed arrays with their constructor instead: `@export var lines := PackedStringArray()`.

const FOLDERS: Array[String] = ["res://scripts", "res://addons", "res://tools"]

var _failures := 0


func _initialize() -> void:
	var pattern := RegEx.create_from_string("@export\\w*(\\(.*\\))?\\s+var\\s+(\\w+)\\s*:\\s*Packed\\w+Array\\s*=\\s*\\[")
	var offenders: Array[String] = []
	for folder in FOLDERS:
		for path in _scripts(folder):
			var text := FileAccess.get_file_as_string(path)
			if text.begins_with("@tool"):
				continue
			for found in pattern.search_all(text):
				offenders.append("%s: %s" % [path, found.get_string(2)])
	for offender in offenders:
		print("   ", offender)
	_check("no exported packed array defaults to an Array literal in a non-@tool script", offenders.is_empty())
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _scripts(folder: String) -> Array[String]:
	var found: Array[String] = []
	var dir := DirAccess.open(folder)
	if dir == null:
		return found
	for file in dir.get_files():
		if file.ends_with(".gd"):
			found.append(folder.path_join(file))
	for sub in dir.get_directories():
		found.append_array(_scripts(folder.path_join(sub)))
	return found


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
