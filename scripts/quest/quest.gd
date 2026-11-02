@tool
class_name Quest
extends Node

## A quest: a state machine whose states are its QuestStep children, built in the editor.
## It starts with the game (`start_active`), when a hero reaches `start_trigger`, or when
## start() is called (wire any signal to it, e.g. another quest's `completed`). Each step runs
## until its goal is met, then hands over to its `next` step or the next sibling; after the
## last one the quest is complete. Only the current step's markers show.
##
## Progress (current step, kill counts, done) lives in the Campaign flags, so it survives
## saves and leaving the map; finished steps' story flags and activated spawners are saved
## with them. The quest tracker (top right) lists the running quests.

signal started
signal step_started(step: QuestStep)
signal completed

const GROUP := &"quests"

@export var title := ""
@export_multiline var description := ""
## Starts as soon as the map does.
@export var start_active := true
## Or starts when a hero reaches this trigger.
@export var start_trigger: MapTrigger
## Shown when it's done.
@export var completion_message := ""

var current: QuestStep
var done := false


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	for step in steps():
		step.end()  # every marker hidden until its step runs
	_resume.call_deferred()  # after the registry and NPCs are set up


## The QuestSteps in order.
func steps() -> Array[QuestStep]:
	var list: Array[QuestStep] = []
	for child in get_children():
		if child is QuestStep:
			list.append(child)
	return list


func is_running() -> bool:
	return current != null and not done


## Starts the quest at its first step (connectable to any signal).
func start(_a: Variant = null, _b: Variant = null) -> void:
	if done or current != null or steps().is_empty():
		return
	started.emit()
	_enter(steps()[0])


## Ends it unfinished (the job there was no time left for): no more steps, gone from the
## tracker, remembered as over. Connectable to any signal (a StoryGate's `opened`).
func abandon(_a: Variant = null, _b: Variant = null) -> void:
	if done:
		return
	if current != null:
		current.end()
	current = null
	done = true
	save()


## Called by the current step when its goal is met.
func step_completed(step: QuestStep) -> void:
	if step != current:
		return
	var following := step.next
	if following == null:
		var list := steps()
		var index := list.find(step)
		following = list[index + 1] if index + 1 < list.size() else null
	if following != null:
		_enter(following)
		return
	current = null
	done = true
	save()
	if not completion_message.is_empty():
		var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
		if party != null and party.commander != null:
			party.commander.show_message(completion_message, Color(1.0, 0.85, 0.4))
			Sounds.play(&"news")
	completed.emit()


## Writes the progress into the Campaign flags.
func save() -> void:
	Campaign.current.set_quest_state(self, {
		"step": str(current.name) if current != null else "",
		"kills": current.kills if current != null else 0,
		"done": done,
	})


func _enter(step: QuestStep) -> void:
	current = step
	step.kills = 0
	save()
	step.begin()
	step_started.emit(step)


func _resume() -> void:
	QuestTracker.ensure(self)
	var state := Campaign.current.quest_state(self)
	if state.get("done", false):
		done = true
		return
	var step_name: String = state.get("step", "")
	var step: QuestStep = null
	if not step_name.is_empty():
		step = get_node_or_null(NodePath(step_name)) as QuestStep
	if step != null:
		current = step
		step.kills = state.get("kills", 0)
		step.begin()
		step_started.emit(step)
	elif start_active:
		start()
	elif start_trigger != null:
		start_trigger.reached.connect(start, CONNECT_ONE_SHOT)
		if start_trigger.fired and start_trigger.once:
			start()


func _get_configuration_warnings() -> PackedStringArray:
	if steps().is_empty():
		return PackedStringArray(["Add QuestStep children: the quest's steps, in order."])
	return PackedStringArray()
