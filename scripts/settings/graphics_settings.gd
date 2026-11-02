class_name GraphicsSettings
extends RefCounted

## Player graphics options, saved to user://settings.cfg. Use GraphicsSettings.get_current();
## systems that depend on an option listen to `changed`.

signal changed

enum Quality { OFF, LOW, MEDIUM, HIGH }

const FILE := "user://settings.cfg"
const SECTION := "graphics"
## Share of each scatter item's density drawn at each quality.
const SCATTER_DENSITY: Array[float] = [0.0, 0.35, 0.65, 1.0]

static var _current: GraphicsSettings

## Terrain scatter (pebbles, grass, flowers): how much is drawn, and which items at all.
var scatter_quality := Quality.HIGH:
	set(value):
		if scatter_quality != value:
			scatter_quality = value
			changed.emit()


static func get_current() -> GraphicsSettings:
	if _current == null:
		_current = GraphicsSettings.new()
		_current.load_file()
	return _current


func scatter_density() -> float:
	return SCATTER_DENSITY[scatter_quality]


func load_file() -> void:
	var config := ConfigFile.new()
	if config.load(FILE) == OK:
		scatter_quality = clampi(config.get_value(SECTION, "scatter_quality", Quality.HIGH), Quality.OFF, Quality.HIGH) as Quality


func save_file() -> void:
	var config := ConfigFile.new()
	config.load(FILE)  # keep other sections
	config.set_value(SECTION, "scatter_quality", scatter_quality)
	config.save(FILE)
