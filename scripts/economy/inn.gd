class_name Inn
extends Node

## An inn (STORY.md: every night costs). Talking to its `host` offers a night's rest for gold.
## Resting heals the party, brings the fallen back, ends the night (TimeOfDay: day), counts a
## day, sets `rest_flags` (`rested`: the day's work waits for it), clears `clear_flags` (what
## could be done once a day) and autosaves. A meal bought with it gives every hero a small
## passive bonus until the next night's rest (Meal).

signal rested(day: int)

const MEAL_BUFF := &"meal"
const MEAL_TIME := 1.0e9  ## until the next rest replaces it

@export var host: NeutralSpawn
@export var title := "A night at the inn"
@export var price := 12
@export var meals: Array[Meal] = []
@export var rest_flags: Array[StringName] = [&"rested"]
@export var clear_flags: Array[StringName] = [&"pit_today"]

var _window: RestWindow


func _ready() -> void:
	_listen.call_deferred()


func _listen() -> void:
	var registry := get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	if registry != null:
		registry.talked_to.connect(_on_talked)
		registry.dialogue_finished.connect(_on_dialogue_finished)


## The campaign's day: 1 on arriving in the valley, one more with every night's rest.
static func day() -> int:
	return Campaign.current.flags.get("day", 1) if Campaign.current != null else 1


func open() -> void:
	if is_instance_valid(_window):
		return
	_window = RestWindow.new()
	_window.inn = self
	get_tree().root.add_child(_window)


## Stays the night with `meal` (or none); "" or why not.
func rest(meal: Meal) -> String:
	var party := EconomyWindow.party()
	var cost := price + (meal.price if meal != null else 0)
	if party == null or not party.spend_gold(cost):
		return "Not enough gold: the night costs %d" % cost
	var registry := get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	for hero in party.heroes():
		if not hero.is_alive():
			hero.revive(1.0)
		registry.set_health(hero.handle, registry.max_health_of(hero.handle))
		hero.mana = hero.max_mana
		hero.remove_buff(MEAL_BUFF)
		hero.remove_buff(ArenaChallenge.FATIGUE)  # a night's sleep: the Pit's fatigue is gone
		if meal != null:
			hero.add_buff(MEAL_BUFF, meal.display_name, meal.icon_glyph, meal.icon_color, meal.description, MEAL_TIME, meal.bonuses)
	Campaign.current.set_story_flag(ArenaChallenge.FATIGUE_FLAG, false)
	var today := day() + 1
	Campaign.current.flags["day"] = today
	for flag in clear_flags:
		Campaign.current.set_story_flag(flag, false)
	for flag in rest_flags:
		Campaign.current.set_story_flag(flag)
	TimeOfDay.apply(get_tree().current_scene, &"day")
	if party.commander != null:
		party.commander.show_message("Morning. Day %d." % today, Color(1.0, 0.85, 0.4))
	Sounds.play(&"news")
	Campaign.current.save_game(Campaign.AUTO_SLOT, "Day %d" % today)
	rested.emit(today)
	return ""


## The host has had its say (its dialogue's lines), then makes the offer; one without lines
## makes it at once.
func _on_talked(npc: int, _speaker: int) -> void:
	if host != null and npc == host.handle and (host.dialogue == null or host.dialogue.lines.is_empty()):
		open()


func _on_dialogue_finished(npc: int, _speaker: int) -> void:
	if host != null and npc == host.handle:
		open()
