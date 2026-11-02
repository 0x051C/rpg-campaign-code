class_name Dialogue
extends Resource

## What a neutral NPC says when a player unit talks to it (smart-click). Shown over its head
## by the DialogueOverlay, one line at a time, the letters streaming in.

## Shown above the text; empty uses the unit's name.
@export var speaker := ""
@export_multiline var lines := PackedStringArray()
@export_range(5.0, 200.0) var characters_per_second := 32.0
## Seconds a fully shown line stays before the next one starts.
@export_range(0.2, 10.0) var line_pause := 1.8
## Where talking again after the last line starts: 0 repeats everything, the last index
## repeats just the last line (a "come back later" line).
@export var repeat_from := 0
