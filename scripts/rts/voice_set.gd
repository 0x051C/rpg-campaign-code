class_name VoiceSet
extends Resource

## A hero's spoken lines, Dota's responses: acknowledging orders, a line per ability, kills,
## pain, death, level-ups. Part of a character prefab (CharacterModel.voice), so the voice
## follows the model. HeroVoice decides when they play. Event names are these properties.

@export var move: Array[AudioStream] = []
@export var attack: Array[AudioStream] = []
@export var kill: Array[AudioStream] = []
## Health dropped below a third.
@export var pain: Array[AudioStream] = []
@export var death: Array[AudioStream] = []
@export var level_up: Array[AudioStream] = []
@export var revive: Array[AudioStream] = []
## A spell that can't be cast yet: on cooldown, not enough mana.
@export var refuse: Array[AudioStream] = []
## A new game starts (the first hero only).
@export var spawn: Array[AudioStream] = []
## Ability id (AbilityDefinition.id(), its file name) -> the line said when casting it. An
## AudioStreamRandomizer picks among several.
@export var abilities: Dictionary[StringName, AudioStream] = {}
@export var volume_db := 0.0


## The lines for `event`, or for `ability` when given.
func lines(event: StringName, ability: AbilityDefinition = null) -> Array[AudioStream]:
	var found: Array[AudioStream] = []
	if ability != null:
		if abilities.has(ability.id()):
			found.append(abilities[ability.id()])
	elif event in self:
		found.assign(get(event))
	return found
