class_name FrameMonitor
extends RefCounted

## What each game system costs, live: custom monitors in the editor's Debugger > Monitors tab
## (and Performance.get_custom_monitor), under "RTS". Systems register theirs when they enter
## the tree and drop them when they leave, timing their own frame work with Time.get_ticks_usec.


static func add(id: StringName, value: Callable) -> void:
	if Performance.has_custom_monitor(id):
		Performance.remove_custom_monitor(id)  # the previous map's, if it is still leaving
	Performance.add_custom_monitor(id, value)


static func remove(id: StringName) -> void:
	if Performance.has_custom_monitor(id):
		Performance.remove_custom_monitor(id)
