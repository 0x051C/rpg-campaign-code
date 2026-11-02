@tool
class_name TutorialLesson
extends Node

## One quiet hint of the Tutorial (its parent): a line of text that shows only when the player
## seems to need it. Its `when` situation has to last `delay` seconds while they still haven't
## done any of the `wait_for` things; it fades out as soon as they do. Whatever the player does
## by themselves is known for good, at any time, so a player who works things out alone never
## sees the hint. Hints higher up in the tree win when several are due.
##
## Things to wait for: what the Commander reports (Commander.acted): "move", "attack",
## "attack_move", "patrol", "follow", "talk", "queue", "stop", "hold", "cancel", "select",
## "box_select", "select_type", "group_saved", "group_recalled", "group_added",
## "group_removed", "hero_hotkey", "next_hero", "center", "aim", "cast", "learn",
## "autocast"; and what the Tutorial watches itself: "camera_pan", "zoom", "overlay",
## "inventory", "quick_save", "paths" (holding Shift).

enum When {
	START,  ## from the start
	NOTHING_SELECTED,  ## no hero is selected
	NPC_NEARBY,  ## someone to talk to near a hero
	ENEMY_NEARBY,  ## an enemy in sight near a hero
	SKILL_POINT,  ## a hero could learn a spell
	SPELL_READY,  ## a spell is ready and an enemy is near
	ITEM_PICKED_UP,  ## the party picked something up
	OBJECTIVE,  ## a quest is running
	LOW_HEALTH,  ## a hero is below a third of their health
	SECOND_HERO,  ## the party has two heroes
	THIRD_HERO,  ## the party has three heroes
}

@export var when := When.START
## The hint; BBCode works ([b]Ctrl+1[/b]). Keep it to a line.
@export_multiline var text := ""
@export var wait_for: PackedStringArray = []
## Seconds the situation lasts, without the player doing it, before the hint shows.
@export var delay := 8.0
## Seconds it stays at most.
@export var show_for := 12.0
## How often it may show at all.
@export var times := 2
