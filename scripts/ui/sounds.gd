class_name Sounds
extends Node

## The game's sound feedback (STORY.md, section 9). Interface cues: an order taken (heroes
## without voice lines), an order refused (escalating: once, twice, three times, then a quieter
## sound for the rest of 10 seconds), buttons, quest news. World cues, heard where they happen:
## loot dropping, a chest opening, a parry, a pressure plate. Spell impacts by element (fire,
## ice, lightning, water), one of five sounds at random.
##
## Each cue has a few players, so fifty hits in a horde fight are a few sounds, not fifty, and
## every play varies the pitch a little. Autoloaded as GameSounds; call the static functions.

const UI := "res://assets/ui/sounds/"
const KENNEY := "res://assets/ui/sounds/kenney_interface-sounds/Audio/"
const IMPACTS := "res://assets/characters/sounds/Basic Spell Impacts/"
const VOICES_PER_CUE := 3
const ERROR_WINDOW_MS := 10000  ## errors this close together escalate, then go quiet
const PITCH_SPREAD := 0.06

## Cue -> [files, volume dB].
const CUES := {
	&"acknowledged": [[UI + "commander_acknowledged.ogg"], -6.0],
	&"error_once": [[UI + "error_once.ogg"], -4.0],
	&"error_twice": [[UI + "error_twice.ogg"], -4.0],
	&"error_triple": [[UI + "error_triple.ogg"], -4.0],
	&"error_rest": [[UI + "error_rest_in_10s_interval.ogg"], -8.0],
	&"item_drop": [[UI + "item_drop.ogg"], -4.0],
	&"clunk": [[UI + "parry_or_chest_open_or_pressure_plate_actuation.ogg"], -4.0],  ## a parry, a chest, a plate
	&"button": [[KENNEY + "click_002.ogg"], -8.0],
	&"news": [[KENNEY + "confirmation_001.ogg"], -6.0],  ## a quest moves on
	&"coin": [[KENNEY + "drop_002.ogg"], -6.0],  ## gold earned on the spot (a round won in the Pit)
	&"footstep": [[], -16.0],  ## a party hero's steps (FilmCow grass and leaves), at their feet
	&"splash": [[], -4.0],  ## water breaking over something (the Pearl's waves)
	&"fire": [[], -6.0],
	&"ice": [[], -6.0],
	&"lightning": [[], -6.0],
	&"water": [[], -6.0],
}
const ELEMENTS := {&"fire": "Fire", &"ice": "Ice", &"lightning": "Lightning", &"water": "Water"}
const AUDIO := "res://assets/audio/"
## Cues whose files are numbered in a folder: cue -> [file pattern, kinds, count].
const NUMBERED := {&"footstep": [AUDIO + "footsteps/%s_%d.ogg", ["grass", "leaves"], 8], &"splash": [AUDIO + "water/splash_%s%d.ogg", [""], 6]}
## The bed under a map's night (or dusk): frogs, insects, a far bird. Day has none yet.
const NIGHT_BED := AUDIO + "ambience/night_swamp.ogg"
const BED_VOLUME := -16.0
const BED_FADE := 2.0

static var current: Sounds

var _streams: Dictionary[StringName, Array] = {}
var _players: Dictionary[StringName, Array] = {}  ## cue -> AudioStreamPlayer
var _players_3d: Dictionary[StringName, Array] = {}  ## cue -> AudioStreamPlayer3D
var _errors: Array[int] = []  ## when the recent errors were (msec)
var _typing: AudioStreamPlayer
var _bed: AudioStreamPlayer  ## the ambience bed (ambience())
var _bed_tween: Tween


func _init() -> void:
	current = self


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for cue: StringName in CUES:
		var files: Array = CUES[cue][0]
		if ELEMENTS.has(cue):
			files = []
			for i in range(1, 6):
				files.append("%s%s Spell Impacts/%s Spell Impact %d.ogg" % [IMPACTS, ELEMENTS[cue], ELEMENTS[cue], i])
		if NUMBERED.has(cue):
			files = []
			for kind: String in NUMBERED[cue][1]:
				for i in range(1, int(NUMBERED[cue][2]) + 1):
					files.append(NUMBERED[cue][0] % [kind, i])
		var streams: Array[AudioStream] = []
		for file: String in files:
			if ResourceLoader.exists(file):
				streams.append(load(file))
		_streams[cue] = streams
	_typing = AudioStreamPlayer.new()
	var typing: AudioStreamOggVorbis = load(UI + "text_scrolling_effect_for_dialogue.ogg").duplicate()
	typing.loop = true
	_typing.stream = typing
	_typing.volume_db = -12.0
	add_child(_typing)
	_bed = AudioStreamPlayer.new()
	_bed.volume_db = -80.0
	add_child(_bed)
	get_tree().node_added.connect(_on_node_added)


## Plays an interface cue.
static func play(cue: StringName) -> void:
	if current != null:
		current._play(cue, Vector3.INF)


## Plays a cue where it happens in the world.
static func play_at(cue: StringName, at: Vector3) -> void:
	if current != null:
		current._play(cue, at)


## An order refused: the first, second and third time each their own sound, then a quieter one
## while they keep coming within ERROR_WINDOW_MS.
static func error() -> void:
	if current == null:
		return
	var now := Time.get_ticks_msec()
	while not current._errors.is_empty() and now - current._errors[0] > ERROR_WINDOW_MS:
		current._errors.pop_front()
	var count := current._errors.size()
	current._errors.append(now)
	play([&"error_once", &"error_twice", &"error_triple"][count] if count < 3 else &"error_rest")


## The map's ambience for its time of day (TimeOfDay): night and dusk have the night bed, fading in;
## day and dawn fade it out.
static func ambience(night: bool) -> void:
	if current == null:
		return
	var bed := current._bed
	if night and not bed.playing:
		var stream: AudioStreamOggVorbis = (load(NIGHT_BED) as AudioStreamOggVorbis).duplicate()
		stream.loop = true
		bed.stream = stream
		bed.volume_db = -60.0
		bed.play()
	if current._bed_tween != null:
		current._bed_tween.kill()
	current._bed_tween = current.create_tween()
	current._bed_tween.tween_property(bed, ^"volume_db", BED_VOLUME if night else -60.0, BED_FADE)
	if not night:
		current._bed_tween.tween_callback(bed.stop)


## Dialogue letters are coming in (on) or not (off): the scrolling sound loops meanwhile.
static func typing(on: bool) -> void:
	if current == null or current._typing.playing == on:
		return
	if on:
		current._typing.play()
	else:
		current._typing.stop()


func _play(cue: StringName, at: Vector3) -> void:
	var streams: Array = _streams.get(cue, [])
	if streams.is_empty():
		return
	var world := at != Vector3.INF
	var pool: Array = (_players_3d if world else _players).get_or_add(cue, [])
	var player: Node = null
	for candidate: Node in pool:
		if not candidate.get(&"playing"):
			player = candidate
			break
	if player == null:
		if pool.size() >= VOICES_PER_CUE:
			return  # enough of this one at once
		player = AudioStreamPlayer3D.new() if world else AudioStreamPlayer.new()
		if world:
			var spatial := player as AudioStreamPlayer3D
			spatial.unit_size = 10.0  # heard from just above the ground the camera looks at (RTSCamera.listener)
			spatial.max_distance = 70.0
		player.set(&"volume_db", CUES[cue][1])
		add_child(player)
		pool.append(player)
	player.set(&"stream", streams.pick_random())
	player.set(&"pitch_scale", randf_range(1.0 - PITCH_SPREAD, 1.0 + PITCH_SPREAD))
	if world:
		(player as AudioStreamPlayer3D).global_position = at
	player.call(&"play")


func _on_node_added(node: Node) -> void:
	if node is BaseButton:
		(node as BaseButton).pressed.connect(func() -> void: play(&"button"))
