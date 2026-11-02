class_name Supper
extends Node

## A supper found on the road (STORY.md: the first one teaches meals): serve() gives every hero of
## the party `meal`'s small blessing until the next night's rest, as the inn's suppers do, and says
## so once. Connect any signal to serve() (a StoryScene's `finished`).

## Shown with the first supper: what meals are.
const LESSON := "Supper: a meal before sleep blesses the party a little until the next night. The inn in Netherby sells them."

@export var meal: Meal
## Shown when it's served; empty: the lesson above.
@export_multiline var message := ""


func serve(_a: Variant = null, _b: Variant = null) -> void:
	if meal == null:
		return
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	if party == null:
		return
	for hero in party.heroes():
		hero.add_buff(Inn.MEAL_BUFF, meal.display_name, meal.icon_glyph, meal.icon_color, meal.description, Inn.MEAL_TIME,
				meal.bonuses)
	if party.commander != null:
		party.commander.show_message(message if not message.is_empty() else LESSON, Color(1.0, 0.85, 0.5))
		Sounds.play(&"news")
