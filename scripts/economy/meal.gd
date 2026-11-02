class_name Meal
extends Resource

## A meal for the night at an inn (Inn): a small passive bonus for every hero until the next
## night's rest, the way Pillars of Eternity: Deadfire's food works. Not the core stats' big
## numbers: regeneration, a touch of Strength, a quicker step.

@export var display_name := "Meal"
@export_multiline var description := ""
@export var price := 4
@export var icon_glyph := "M"
@export var icon_color := Color(0.85, 0.65, 0.35)
@export var bonuses: Dictionary[Stats.Stat, float] = {}
