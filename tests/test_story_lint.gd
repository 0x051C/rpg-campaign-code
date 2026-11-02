extends SceneTree
## The story linter: every map (and every generated layout of it) is loaded and its story checked for the kinds of
## softlock a playthrough keeps finding: a TALK step whose person has nothing to say (a neutral without lines is only
## followed, never talked to), a step with nothing to reach, kill or find, an exit to a map that isn't there, a
## scene with no lines, a quest with no steps. Static checks: reachability is the critical-path bot's job (next).

const MAP_FOLDERS := ["res://scenes/maps/", "res://scenes/maps/story/"]
const SKIP := ["story_template.tscn", "caldavar.tscn", "pit.tscn"]  # the template; the lane map; the arena has its own rules

var _problems := 0
var _maps := 0


func _initialize() -> void:
	for folder in MAP_FOLDERS:
		for file in DirAccess.get_files_at(folder):
			if file.ends_with(".tscn") and not SKIP.has(file):
				_lint(folder + file)
	print("maps linted: %d, problems: %d" % [_maps, _problems])
	print("FAILURES: %d" % _problems)
	quit(1 if _problems > 0 else 0)


func _lint(path: String) -> void:
	var map: Node = (load(path) as PackedScene).instantiate()
	_maps += 1
	for node in map.find_children("*", "", true, false):
		if node is QuestStep:
			_step(path, node)
		elif node is StoryScene and (node as StoryScene).lines.is_empty():
			_problem(path, node, "a scene with no lines")
		elif node is Quest and (node as Quest).steps().is_empty():
			_problem(path, node, "a quest with no steps")
		elif node is MapExit:
			var target := (node as MapExit).target_map
			if target.is_empty() or not ResourceLoader.exists(target):
				_problem(path, node, "an exit to a map that isn't there: '%s'" % target)
		elif node is NeutralSpawn and (node as NeutralSpawn).definition == null:
			_problem(path, node, "a person with no unit definition")
	map.free()


func _step(path: String, step: QuestStep) -> void:
	match step.goal:
		QuestStep.Goal.TALK:
			if step.npc == null:
				_problem(path, step, "TALK with nobody to talk to")
			elif step.npc.dialogue == null or step.npc.dialogue.lines.is_empty():
				_problem(path, step, "TALK to %s, who has no lines (a right-click would only follow it)" % step.npc.name)
		QuestStep.Goal.REACH:
			if step.trigger == null:
				_problem(path, step, "REACH with no trigger")
		QuestStep.Goal.KILL:
			if step.npc == null and step.kill_unit == null:
				_problem(path, step, "KILL with nothing to kill")
		QuestStep.Goal.ITEM:
			if step.item == null:
				_problem(path, step, "ITEM with no item")
		QuestStep.Goal.FLAG:
			if step.flag == &"":
				_problem(path, step, "FLAG with no flag")
	if step.objective.strip_edges().is_empty():
		_problem(path, step, "a step with no objective text")


func _problem(path: String, node: Node, what: String) -> void:
	_problems += 1
	print("FAIL %s: %s (%s)" % [path.get_file(), what, node.name])
