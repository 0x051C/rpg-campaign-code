class_name StoryScene
extends Node

## A short scene told in the engine, Warcraft III style: the game pauses, black bars close in,
## the camera goes to whoever speaks, and their lines scroll in at the bottom, one after the
## other. Each line moves on by itself after time to read it; Space, Enter or a click hurries
## it on, Esc skips the rest.
##
## Write the lines as "Speaker: text"; a line without a speaker goes on with the last one.
## A speaker is a party hero or a companion (Brook) by name, or a name listed in `speakers`,
## with the NeutralSpawn, Unit or any Node3D standing for them; list a voice from nowhere (the
## Patron) with an empty path. The camera goes to whoever speaks.
##
## play() starts it; connect any signal to it (a QuestStep's `completed`, a MapTrigger's
## `reached`, a StoryGate's `opened`), or switch on `play_on_start`. It plays once per campaign
## unless `once` is off, and only while its flags say so (`only_if`, `unless`).

signal finished

const TYPING_SOUND := preload("res://assets/ui/sounds/text_scrolling_effect_for_dialogue.ogg")
const CHARACTERS_PER_SECOND := 45.0
const READ_TIME := 1.6  ## seconds a line stays after it's fully shown...
const READ_TIME_PER_CHARACTER := 0.035  ## ...plus this per character
const BAR_COLOR := Color(0, 0, 0, 0.92)
const NAME_COLOR := Color(0.95, 0.8, 0.45)

@export_multiline var lines := PackedStringArray()
## Who stands for a speaker's name.
@export var speakers: Dictionary[String, NodePath] = {}
@export var play_on_start := false
@export var once := true
@export var only_if: Array[StringName] = []
@export var unless: Array[StringName] = []
@export_group("Afterwards")
@export var set_flags: Array[StringName] = []
## The time of day the map turns to (TimeOfDay presets: night, dawn, day, dusk); empty keeps it.
@export var time_of_day := &""
## The map the party travels to when it's over (the title screen ends the game); empty: stay.
@export_file("*.tscn") var travel_to := ""

var playing := false

## Scenes playing right now: none may be saved halfway (Campaign.save_refusal).
static var active := 0
## Whether the game was paused before the first of the scenes playing began: scenes can overlap (a step
## completing may start two), and the last one to end must restore that, not what the one before it left.
static var _paused_before := false

var _layer: CanvasLayer
var _name_label: Label
var _text_label: Label
var _sound: AudioStreamPlayer
var _index := -1
var _speaker := ""
var _shown := 0.0  ## characters of the current line shown so far
var _wait := 0.0  ## reading time left once the line is complete
var _hud: CanvasLayer  ## the map's HUD, hidden while the scene plays


func _ready() -> void:
	if play_on_start:
		play.call_deferred()


func _exit_tree() -> void:
	if playing:  # the map changed under it (a load): not played, nothing set
		playing = false
		active -= 1


## Whether its flags let it play now.
func can_play() -> bool:
	if Campaign.current == null or lines.is_empty() or playing:
		return false
	if once and Campaign.current.is_opened(self):
		return false
	for flag in only_if:
		if not Campaign.current.has_story_flag(flag):
			return false
	for flag in unless:
		if Campaign.current.has_story_flag(flag):
			return false
	return true


func play(_a: Variant = null, _b: Variant = null) -> void:
	if not can_play() or not is_inside_tree():
		return
	if active == 0:
		_paused_before = get_tree().paused
	playing = true
	active += 1
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().paused = true
	_hud = get_tree().current_scene.get_node_or_null(^"HUD") as CanvasLayer
	if _hud != null:
		_hud.visible = false  # only the bars and the lines, Warcraft III style
	_build()
	_index = -1
	_speaker = ""
	_next_line()


## Ends it now, as if every line had been read.
func skip() -> void:
	if playing:
		_finish()


func _process(delta: float) -> void:
	if not playing:
		return
	var text := _text_label.text
	if _shown < text.length():
		_shown = minf(_shown + delta * CHARACTERS_PER_SECOND * _speed(), text.length())
		_text_label.visible_characters = int(_shown)
		if _shown >= text.length():
			_sound.stop()
		return
	_wait -= delta * _speed()
	if _wait <= 0.0:
		_next_line()


func _input(event: InputEvent) -> void:
	if not playing:
		return
	if event.is_action_pressed(&"ui_cancel"):
		_finish()
	elif event.is_action_pressed(&"ui_accept") or (event is InputEventMouseButton and event.is_pressed()):
		_hurry()
	else:
		return
	get_viewport().set_input_as_handled()


## Game time runs faster in the tests; reading follows it.
func _speed() -> float:
	return maxf(Engine.time_scale, 1.0)


func _hurry() -> void:
	if _shown < _text_label.text.length():
		_shown = _text_label.text.length()
		_text_label.visible_characters = -1
		_sound.stop()
	else:
		_next_line()


func _next_line() -> void:
	_index += 1
	if _index >= lines.size():
		_finish()
		return
	var line := lines[_index].strip_edges()
	var colon := line.find(":")
	if colon > 0 and _is_speaker(line.substr(0, colon).strip_edges()):
		_speaker = line.substr(0, colon).strip_edges()
		line = line.substr(colon + 1).strip_edges()
	_name_label.text = _speaker
	_text_label.text = line
	_text_label.visible_characters = 0
	_shown = 0.0
	_wait = READ_TIME + READ_TIME_PER_CHARACTER * line.length()
	_sound.play()
	var where := _place_of(_speaker)
	var camera := get_tree().current_scene.get_node_or_null(^"RTSCamera") as RTSCamera
	if where != Vector3.INF and camera != null:
		camera.center_on(where)


## A name that stands for someone: a key of `speakers`, or a hero or companion of that name.
func _is_speaker(speaker_name: String) -> bool:
	return speakers.has(speaker_name) or _unit_named(speaker_name) != null


## Where the speaker stands; INF if nobody does.
func _place_of(speaker_name: String) -> Vector3:
	if speakers.has(speaker_name) and not speakers[speaker_name].is_empty():
		var node := get_node_or_null(speakers[speaker_name])
		if node is NeutralSpawn:
			var registry := get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
			var spawn := node as NeutralSpawn
			if registry != null and registry.is_alive(spawn.handle):
				return registry.position_of(spawn.handle)
		if node is Node3D:
			return (node as Node3D).global_position
	var unit := _unit_named(speaker_name)
	return unit.global_position if unit != null else Vector3.INF


func _unit_named(speaker_name: String) -> Unit:
	var registry := get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	if registry == null or speaker_name.is_empty():
		return null
	for unit in registry.unit_nodes():
		if unit.definition.display_name == speaker_name and unit.is_alive():
			return unit
	return null


func _finish() -> void:
	playing = false
	active -= 1
	if once:
		Campaign.current.mark_opened(self)  # played: only once it's over, with its flags
	_sound.stop()
	_layer.queue_free()
	if active == 0:  # the last one over: the HUD and the game come back as they were
		if is_instance_valid(_hud):
			_hud.visible = true
		get_tree().paused = _paused_before
	process_mode = Node.PROCESS_MODE_INHERIT
	for flag in set_flags:
		Campaign.current.set_story_flag(flag)
	if not time_of_day.is_empty():
		TimeOfDay.apply(get_tree().current_scene, time_of_day)
	finished.emit()
	if travel_to == Campaign.TITLE_SCENE:
		Campaign.current.quit_to_title()
	elif not travel_to.is_empty():
		Campaign.current.travel(travel_to)


## The black bars, the speaker's name and the text.
func _build() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 120  # over everything the map draws
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_layer)
	var top := ColorRect.new()
	top.color = BAR_COLOR
	top.anchor_right = 1.0
	top.anchor_bottom = 0.1
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(top)
	var bottom := ColorRect.new()
	bottom.color = BAR_COLOR
	bottom.anchor_top = 0.78
	bottom.anchor_right = 1.0
	bottom.anchor_bottom = 1.0
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(bottom)
	var column := VBoxContainer.new()
	column.anchor_left = 0.18
	column.anchor_right = 0.82
	column.anchor_top = 0.08
	column.anchor_bottom = 0.92
	column.add_theme_constant_override(&"separation", 6)
	bottom.add_child(column)
	_name_label = Label.new()
	_name_label.add_theme_color_override(&"font_color", NAME_COLOR)
	_name_label.add_theme_font_size_override(&"font_size", 22)
	column.add_child(_name_label)
	_text_label = Label.new()
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text_label.add_theme_font_size_override(&"font_size", 20)
	_text_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_text_label)
	var hint := Label.new()
	hint.text = "Space: next     Esc: skip"
	hint.add_theme_color_override(&"font_color", Color(1, 1, 1, 0.35))
	hint.add_theme_font_size_override(&"font_size", 13)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	column.add_child(hint)
	_sound = AudioStreamPlayer.new()
	var typing: AudioStreamOggVorbis = TYPING_SOUND.duplicate()
	typing.loop = true  # for as long as letters are coming
	_sound.stream = typing
	_sound.bus = &"Master"
	_sound.volume_db = -8.0
	_layer.add_child(_sound)
