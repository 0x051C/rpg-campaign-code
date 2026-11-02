class_name HeroVoice
extends AudioStreamPlayer

## Plays a hero's VoiceSet to its own player, unpositioned like Dota's hero responses.
## One hero talks at a time: a line interrupts only a lower-priority one, so an
## acknowledgment never cuts off a spell's line. Acknowledgments, refusals, kills and pain
## have cooldowns (Dota-like pacing) so orders don't turn into chatter, and the same line
## doesn't come twice in a row.

## event: [priority, chance, cooldown seconds]. "ability" is any ability's own line.
const RULES: Dictionary[StringName, Array] = {
	&"move": [1, 1.0, 5.0],
	&"attack": [1, 1.0, 5.0],
	&"refuse": [1, 1.0, 3.0],
	&"kill": [2, 0.4, 10.0],
	&"pain": [2, 1.0, 20.0],
	&"ability": [3, 1.0, 0.0],
	&"level_up": [3, 1.0, 0.0],
	&"revive": [3, 1.0, 0.0],
	&"spawn": [3, 1.0, 0.0],
	&"death": [4, 1.0, 0.0],
}
## Events sharing one cooldown: a move right after an attack order stays quiet.
const SHARED_COOLDOWN: Dictionary[StringName, StringName] = {&"move": &"order", &"attack": &"order"}

static var _speaker: HeroVoice  ## whoever is talking now

var voice: VoiceSet
var _priority := 0
var _ready_at: Dictionary[StringName, float] = {}  ## cooldown group -> engine time it may play again
var _last_line: AudioStream


static func create(voice_set: VoiceSet) -> HeroVoice:
	var player := HeroVoice.new()
	player.name = &"Voice"
	player.voice = voice_set
	player.volume_db = voice_set.volume_db
	return player


## Says a line for `event` (a VoiceSet property, or "ability" with `ability`) if the rules
## allow. Returns whether it speaks.
func say(event: StringName, ability: AbilityDefinition = null) -> bool:
	var rule: Array = RULES[event]
	var now := Time.get_ticks_msec() / 1000.0
	var group: StringName = SHARED_COOLDOWN.get(event, event)
	if now < _ready_at.get(group, 0.0) or randf() > rule[1]:
		return false
	if is_instance_valid(_speaker) and _speaker.playing and _speaker._priority >= rule[0]:
		return false
	var choices := voice.lines(event, ability)
	if choices.size() > 1:
		choices.erase(_last_line)
	if choices.is_empty():
		return false
	if is_instance_valid(_speaker) and _speaker != self:
		_speaker.stop()
	_speaker = self
	_priority = rule[0]
	_last_line = choices.pick_random()
	stream = _last_line
	play()
	_ready_at[group] = now + rule[2]
	return true


func _exit_tree() -> void:
	stop()  # a line still playing at quit would keep its stream alive past shutdown
