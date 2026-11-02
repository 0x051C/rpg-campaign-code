class_name ClassPassive
extends Resource

## One small passive on a hero's item bar: a class trait, or a faction trait such as Undead.
## Each does one thing, so the player can see at a glance where a bonus comes from (one
## turns Dexterity into armor, another Willpower into spell damage). Most turn a core stat
## into a bonus; some only describe a rule. Hover only; never cast.

@export var display_name := "Passive"
@export_multiline var description := ""
@export var icon_glyph := "C"
@export var icon_color := Color.GRAY
@export var conversions: Array[StatConversion] = []
## Flat bonuses the passive gives regardless of stats, e.g. Backstab's base damage.
@export var bonuses: Dictionary[Stats.Stat, float] = {}
