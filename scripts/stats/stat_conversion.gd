class_name StatConversion
extends Resource

## One line of a class passive: every point of the core stat `from` adds `per_point` of `to`.

@export var from := Stats.Stat.STRENGTH
@export var to := Stats.Stat.ARMOR
@export var per_point := 0.1
