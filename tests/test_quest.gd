extends SceneTree
## Quest state machine, MapTrigger and spawner activation, set up like a map would be in
## the editor (packed into user://quest_test.tscn), played through with a save and load.

const MAP := "user://quest_test.tscn"
var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var map: Node3D = load("res://scenes/main.tscn").instantiate()
	map.set("starting_party", [load("res://data/units/knight.tres"), load("res://data/units/mage.tres")] as Array[UnitDefinition])
	var start: Vector3 = (map.get_node("HeroStart") as Node3D).position
	var north: CreepSpawner = map.get_node("NorthSpawner")
	north.active = false
	(map.get_node("SouthSpawner") as CreepSpawner).active = false
	(map.get_node("CreepWaves") as CreepWaves).first_wave_delay = 9999.0

	var trigger := MapTrigger.new()
	trigger.name = "BridgeTrigger"
	trigger.shape = MapTrigger.Shape.BOX
	trigger.size = Vector3(6, 4, 3)
	trigger.position = start + Vector3(0, 0, -12)
	var marker_a: MapMarker = load("res://scenes/markers/objective.tscn").instantiate()
	marker_a.name = "BridgeMarker"
	marker_a.position = trigger.position
	var marker_b: MapMarker = load("res://scenes/markers/objective.tscn").instantiate()
	marker_b.name = "CampMarker"
	marker_b.position = start + Vector3(0, 0, -30)
	var quest := Quest.new()
	quest.name = "Prologue"
	quest.title = "The Lane"
	quest.completion_message = "Quest complete: The Lane"
	var reach := QuestStep.new()
	reach.name = "ReachBridge"
	reach.objective = "Reach the bridge"
	reach.goal = QuestStep.Goal.REACH
	reach.trigger = trigger
	reach.markers = [marker_a] as Array[MapMarker]
	reach.message = "The skeletons have noticed you!"
	reach.set_flags = [&"bridge_reached"] as Array[StringName]
	reach.activate_spawners = [north] as Array[CreepSpawner]
	var kill := QuestStep.new()
	kill.name = "KillMinions"
	kill.objective = "Kill skeleton minions"
	kill.goal = QuestStep.Goal.KILL
	kill.kill_unit = load("res://data/units/skeleton_minion.tres")
	kill.kill_count = 2
	kill.markers = [marker_b] as Array[MapMarker]
	var wait := QuestStep.new()
	wait.name = "Report"
	wait.objective = "Tell the innkeeper"
	wait.goal = QuestStep.Goal.FLAG
	wait.flag = &"told_innkeeper"
	for node: Node in [trigger, marker_a, marker_b, quest]:
		map.add_child(node)
	for step: Node in [reach, kill, wait]:
		quest.add_child(step)
	for node in map.find_children("*", "", true, false):
		if node.owner == null:
			node.owner = map
	var packed := PackedScene.new()
	packed.pack(map)
	ResourceSaver.save(packed, MAP)
	map.free()

	Campaign.current.flags = {}
	change_scene_to_file(MAP)
	await create_timer(1.5).timeout
	map = current_scene
	(map.get_node("RTSCamera") as RTSCamera).edge_scroll = false
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var commander: Commander = map.get_node("Commander")
	quest = map.get_node("Prologue")
	trigger = map.get_node("BridgeTrigger")
	north = map.get_node("NorthSpawner")
	marker_a = map.get_node("BridgeMarker")
	marker_b = map.get_node("CampMarker")
	var tracker := map.get_node_or_null("QuestTracker") as QuestTracker
	await create_timer(0.4).timeout
	_check("the quest starts at its first step", quest.current != null and quest.current.name == "ReachBridge")
	_check("only the current step's marker shows", marker_a.visible and not marker_b.visible)
	_check("the tracker lists it", tracker != null and tracker._label.text.contains("Reach the bridge"))
	_check("the spawner waits", not north.active and _team_creeps(registry, 2) == 0)

	# A hero walks into the box (but first stands just beside it)
	var hero := registry.unit_of(commander.heroes[0])
	hero.teleport(trigger.global_position + Vector3(3.5, 0, 0))
	await create_timer(0.5).timeout
	_check("beside the box doesn't count", quest.current.name == "ReachBridge")
	hero.teleport(trigger.global_position + Vector3(2.5, 0, 1.0))
	await create_timer(0.5).timeout
	_check("inside the box: step done, on to the next", quest.current.name == "KillMinions")
	_check("its story flag is set", Campaign.current.has_story_flag(&"bridge_reached"))
	_check("the spawner woke up and sent a wave", north.active and _team_creeps(registry, 2) > 0)
	_check("markers swapped", not marker_a.visible and marker_b.visible)

	# One kill, then save and load
	var minion := _first_creep(registry, 2, "Skeleton Minion")
	registry.apply_damage(minion, 99999.0, hero.handle, false)
	await create_timer(0.3).timeout
	_check("kills count (1/2)", tracker._label.text.contains("(1/2)"))
	_check("save", Campaign.current.save_game("quest").is_empty())
	Campaign.current.load_game("quest")
	await Campaign.current.loaded
	await create_timer(0.6).timeout
	map = current_scene
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	quest = map.get_node("Prologue")
	north = map.get_node("NorthSpawner")
	marker_a = map.get_node("BridgeMarker")
	marker_b = map.get_node("CampMarker")
	tracker = map.get_node_or_null("QuestTracker") as QuestTracker
	await create_timer(0.3).timeout
	_check("after loading: same step, same kill count", quest.current != null and quest.current.name == "KillMinions"
			and quest.current.kills == 1)
	_check("the trigger stays fired, the spawner stays active", (map.get_node("BridgeTrigger") as MapTrigger).fired and north.active)
	_check("markers restored", not marker_a.visible and marker_b.visible)

	hero = registry.unit_of(commander.heroes[0])
	registry.apply_damage(_first_creep(registry, 2, "Skeleton Minion"), 99999.0, hero.handle, false)
	await create_timer(0.3).timeout
	_check("second kill: on to the flag step", quest.current != null and quest.current.name == "Report")
	var finished := [false]
	quest.completed.connect(func() -> void: finished[0] = true)
	Campaign.current.set_story_flag(&"told_innkeeper")
	await create_timer(0.8).timeout
	_check("the flag completes the quest", quest.done and finished[0] and not quest.is_running())
	await create_timer(0.3).timeout
	_check("the tracker empties", not tracker._label.visible)
	print("FAILURES: %d" % _failures)
	quit()


func _team_creeps(registry: UnitRegistry, team: int) -> int:
	return registry.count_alive(UnitRegistry.Kind.NPC, team)


func _first_creep(registry: UnitRegistry, team: int, display: String) -> int:
	for handle in registry.handles():
		if registry.team_of(handle) == team and registry.definition_of(handle).display_name == display:
			return handle
	return UnitRegistry.NONE


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
