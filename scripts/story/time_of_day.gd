class_name TimeOfDay
extends Node

## The time of day, scripted (STORY.md: no clock, the story says when night falls): sets the
## map's sun or moon (its first DirectionalLight3D) and its WorldEnvironment's ambient light to a
## preset. Place one in a map for its starting time; a StoryScene can change it afterwards
## (`time_of_day`), and so can TimeOfDay.apply() from anywhere. The campaign remembers each map's
## time, so a save or a return finds it as it was left.

const PRESETS := {
	&"night": {"color": Color(0.55, 0.65, 1.0), "energy": 0.35, "pitch": -35.0, "ambient": 0.25, "ambient_color": Color(0.35, 0.4, 0.6)},
	&"dawn": {"color": Color(1.0, 0.72, 0.55), "energy": 0.8, "pitch": -12.0, "ambient": 0.55, "ambient_color": Color(0.8, 0.65, 0.6)},
	&"day": {"color": Color(1.0, 0.97, 0.9), "energy": 1.3, "pitch": -55.0, "ambient": 1.0, "ambient_color": Color(0.8, 0.85, 0.9)},
	&"dusk": {"color": Color(1.0, 0.55, 0.35), "energy": 0.7, "pitch": -10.0, "ambient": 0.45, "ambient_color": Color(0.7, 0.5, 0.5)},
}

## The map's time when it's first entered; "as built" keeps the lights the map was made with
## (until a StoryScene changes the time).
@export_enum("as built", "night", "dawn", "day", "dusk") var preset := "as built"


func _ready() -> void:
	var map := _map()
	var time := StringName(preset)
	if Campaign.current != null and map != null:
		time = Campaign.current.flags.get("time_of_day", {}).get(map.scene_file_path, time)
	_light(map, time)  # "as built": nothing to change


func _map() -> Node:
	return owner if owner != null else get_parent()


## The night bed for night and dusk; "as built" goes by the map's own light: a moon (by name, as in the
## prologue) or a dim sun is night.
static func _ambience(map: Node, time: StringName) -> void:
	var night := time == &"night" or time == &"dusk"
	if not PRESETS.has(time):
		var lights := map.find_children("*", "DirectionalLight3D", true, false)
		if not lights.is_empty():
			var light := lights[0] as DirectionalLight3D
			night = String(light.name).to_lower().contains("moon") or light.light_energy < 0.6
	Sounds.ambience(night)


## Turns `map` to `time` (a PRESETS key) and remembers it for the map.
static func apply(map: Node, time: StringName) -> void:
	if map == null or not PRESETS.has(time):
		return
	_light(map, time)
	if Campaign.current != null:
		var times: Dictionary = Campaign.current.flags.get_or_add("time_of_day", {})
		times[map.scene_file_path] = time


static func _light(map: Node, time: StringName) -> void:
	if map == null:
		return
	_ambience(map, time)
	if not PRESETS.has(time):
		return
	var values: Dictionary = PRESETS[time]
	var lights := map.find_children("*", "DirectionalLight3D", true, false)
	if not lights.is_empty():
		var light := lights[0] as DirectionalLight3D
		light.light_color = values.color
		light.light_energy = values.energy
		light.rotation_degrees.x = values.pitch
	var environments := map.find_children("*", "WorldEnvironment", true, false)
	if not environments.is_empty():
		var world := environments[0] as WorldEnvironment
		if world.environment != null:
			world.environment = world.environment.duplicate()  # not the resource other maps share
			world.environment.ambient_light_energy = values.ambient
			world.environment.ambient_light_color = values.ambient_color
