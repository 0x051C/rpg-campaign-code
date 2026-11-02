class_name DevConsole
extends CanvasLayer

## The developer console, for testing fast: ` (the key left of 1) opens and closes it, in debug builds only
## (editor runs, debug exports). Type `help`. Several commands go on one line with ";". Tab completes command
## names and their arguments (units, items, maps, flags, presets), Up and Down walk the history (kept between
## runs), Esc closes. It works while the game is paused (story scenes, menus).
##
## Presets: `exec <name>` runs the lines of data/console/<name>.txt ("#" starts a comment), for a state to test
## from ("the vigil with a levelled party"). From the command line, `-- --console="gold 500; level 6"` runs once
## the first map is up, e.g. `godot --path . scenes/maps/prologue.tscn -- --console="exec vigil_ready"`.

const TOGGLE_KEY := KEY_QUOTELEFT
const HISTORY_FILE := "user://console_history.txt"
const MAX_HISTORY := 200
const PRESETS := "res://data/console/"
const UNITS := "res://data/units/"
const ITEMS := "res://data/items/"
const MAPS := "res://scenes/maps/"
const ENEMY_TEAM := 2
const OUTPUT_COLOR := Color(0.85, 0.85, 0.8)
const ERROR_COLOR := Color(1.0, 0.45, 0.4)
const ECHO_COLOR := Color(0.55, 0.75, 1.0)
const RARITIES: Dictionary[String, ItemDefinition.Rarity] = {
	"common": ItemDefinition.Rarity.COMMON, "magic": ItemDefinition.Rarity.MAGIC,
	"rare": ItemDefinition.Rarity.RARE, "legendary": ItemDefinition.Rarity.LEGENDARY,
}
## name: [arguments, what it does]. Each has a `_cmd_<name>(args) -> String` (an error starts with "!").
const COMMANDS: Dictionary[String, Array] = {
	"help": ["[command]", "lists the commands, or tells about one"],
	"clear": ["", "empties the console"],
	"gold": ["<n> | +n | -n", "sets the party's gold, or adds to it"],
	"level": ["<n>", "raises every hero to level n (with its skill points)"],
	"xp": ["<n>", "gives every hero n experience"],
	"points": ["<n>", "gives every hero n skill points"],
	"god": ["", "the party takes no damage (toggles; stays on across maps)"],
	"heal": ["", "full health and mana for the party; the fallen get up"],
	"refresh": ["", "ends every spell and item cooldown of the party"],
	"give": ["<item> [rarity] [level]", "puts an item in the bag; with a rarity, rolled like a drop (common magic rare legendary)"],
	"loot": ["[level] [rarity]", "a random rolled item in the bag (a random rarity without one)"],
	"spawn": ["<unit> [count] [team]", "units at the cursor (team 2, the enemy, by default; 0 neutral)"],
	"kill": ["[radius]", "kills the enemies within radius m of the cursor (8)"],
	"killall": ["", "kills every enemy on the map"],
	"tp": ["", "the party to the cursor"],
	"flag": ["<name> [0]", "sets a story flag (0 clears it)"],
	"flags": ["", "lists the story flags set"],
	"quest": ["", "lists the map's quests and where each stands"],
	"step": ["[quest]", "completes the current step of a running quest (the first, or the one named)"],
	"skip": ["", "ends the story scenes playing"],
	"map": ["<map> [arrival]", "travels to a map with the party (a name: prologue, village, vigil...)"],
	"maps": ["", "lists the maps"],
	"time": ["<scale>", "game speed (1 is normal)"],
	"tod": ["<night|dawn|day|dusk>", "the time of day"],
	"fog": ["", "the fog of war off or on (toggles)"],
	"exec": ["<preset>", "runs data/console/<preset>.txt"],
}

static var current: DevConsole

var god := false

var _panel := PanelContainer.new()
var _log := RichTextLabel.new()
var _line := LineEdit.new()
var _history := PackedStringArray()
var _history_at := 0
var _pending := PackedStringArray()  ## from the command line, run once a map is up
var _spawners: Dictionary[int, CreepSpawner] = {}  ## team: the hidden spawner `spawn` uses on this map
var _completions := PackedStringArray()  ## Tab cycles through them
var _completion_at := -1
var _completion_base := ""


func _ready() -> void:
	if not OS.is_debug_build():
		queue_free()
		return
	current = self
	layer = 128  # over the HUD, the menus and story scenes
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	visible = false
	_load_history()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--console="):
			_pending.append(arg.trim_prefix("--console=").trim_prefix("\"").trim_suffix("\""))


func _process(_delta: float) -> void:
	var registry := _registry()
	if registry == null:
		return
	if god and registry.god_team != registry.player_team:
		registry.god_team = registry.player_team  # a new map: god mode stays on
	if not _pending.is_empty() and _party() != null and not _party().heroes().is_empty():
		var lines := _pending
		_pending = PackedStringArray()
		for line in lines:
			run(line)


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	if key.physical_keycode == TOGGLE_KEY and not key.echo:
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not visible:
		return
	match key.keycode:
		KEY_ESCAPE:
			toggle()
		KEY_UP:
			_walk_history(-1)
		KEY_DOWN:
			_walk_history(1)
		KEY_TAB:
			_complete()
		_:
			_completion_at = -1
			return
	get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	if visible:
		_line.grab_focus.call_deferred()
	else:
		_line.release_focus()


## Runs a line: one or more commands separated by ";". Their output goes to the console (and stdout).
func run(line: String) -> void:
	for part in line.split(";", false):
		var words := part.strip_edges().split(" ", false)
		if words.is_empty():
			continue
		_print("> " + part.strip_edges(), ECHO_COLOR)
		var command := words[0].to_lower()
		if not COMMANDS.has(command):
			_print("Unknown command: %s (help lists them)" % command, ERROR_COLOR)
			continue
		var result: String = call("_cmd_" + command, words.slice(1))
		if result.begins_with("!"):
			_print(result.substr(1), ERROR_COLOR)
		elif not result.is_empty():
			_print(result, OUTPUT_COLOR)


# --- Commands ------------------------------------------------------------------

func _cmd_help(args: PackedStringArray) -> String:
	if not args.is_empty():
		var entry: Array = COMMANDS.get(args[0].to_lower(), [])
		return "%s %s: %s" % [args[0], entry[0], entry[1]] if not entry.is_empty() else "!No command %s" % args[0]
	var lines := PackedStringArray()
	for command in COMMANDS:
		lines.append("%-9s %-26s %s" % [command, COMMANDS[command][0], COMMANDS[command][1]])
	return "\n".join(lines)


func _cmd_clear(_args: PackedStringArray) -> String:
	_log.clear()
	return ""


func _cmd_gold(args: PackedStringArray) -> String:
	var party := _party()
	if party == null:
		return "!No party here"
	if args.is_empty() or not args[0].lstrip("+-").is_valid_int():
		return "!gold <n> | +n | -n"
	var amount := args[0].to_int()
	party.add_gold(amount if args[0].begins_with("+") or args[0].begins_with("-") else amount - party.gold)
	return "Gold: %d" % party.gold


func _cmd_level(args: PackedStringArray) -> String:
	if args.is_empty() or not args[0].is_valid_int():
		return "!level <n>"
	var target := clampi(args[0].to_int(), 1, Unit.MAX_LEVEL)
	var lines := PackedStringArray()
	for hero in _heroes():
		if target > hero.level:
			hero.add_experience(Unit.EXPERIENCE_TABLE[target - 1] - hero.experience)
		lines.append("%s: level %d, %d skill points" % [hero.definition.display_name, hero.level, hero.skill_points])
	return "\n".join(lines) if not lines.is_empty() else "!No heroes here"


func _cmd_xp(args: PackedStringArray) -> String:
	if args.is_empty() or not args[0].is_valid_float():
		return "!xp <n>"
	for hero in _heroes():
		hero.add_experience(args[0].to_float())
	return "+%s experience" % args[0]


func _cmd_points(args: PackedStringArray) -> String:
	if args.is_empty() or not args[0].is_valid_int():
		return "!points <n>"
	for hero in _heroes():
		hero.skill_points += args[0].to_int()
	return "+%s skill points each" % args[0]


func _cmd_god(_args: PackedStringArray) -> String:
	god = not god
	var registry := _registry()
	if registry != null:
		registry.god_team = registry.player_team if god else -1
	return "God mode " + ("on" if god else "off")


func _cmd_heal(_args: PackedStringArray) -> String:
	var registry := _registry()
	for hero in _heroes():
		if not hero.is_alive():
			hero.revive(1.0)
		registry.heal(hero.handle, registry.max_health_of(hero.handle))
		hero.mana = hero.max_mana
	return "Healed"


func _cmd_refresh(_args: PackedStringArray) -> String:
	for hero in _heroes():
		hero.ability_cooldowns.fill(0.0)
		hero.item_cooldowns.fill(0.0)
	return "Cooldowns done"


func _cmd_give(args: PackedStringArray) -> String:
	var party := _party()
	if party == null or args.is_empty():
		return "!give <item> [rarity] [level]"
	var path := ITEMS + args[0] + ".tres"
	if not ResourceLoader.exists(path):
		return "!No item %s (Tab lists them)" % args[0]
	var item: ItemDefinition = load(path)
	if args.size() > 1:
		if not RARITIES.has(args[1]):
			return "!Rarity: common, magic, rare or legendary"
		item = LootRoller.roll(item, args[2].to_int() if args.size() > 2 else _level(), RARITIES[args[1]])
	if not party.add(item):
		return "!The bag is too heavy for %s" % item.display_name
	return "In the bag: " + item.display_name


func _cmd_loot(args: PackedStringArray) -> String:
	var party := _party()
	if party == null:
		return "!No party here"
	var level := args[0].to_int() if not args.is_empty() and args[0].is_valid_int() else _level()
	var item: ItemDefinition
	var rarity := args[1] if args.size() > 1 else ""
	if rarity == "legendary":
		item = LootRoller.random_legendary(level)
	elif RARITIES.has(rarity):
		item = LootRoller.roll(LootRoller.catalog().loot_bases.pick_random(), level, RARITIES[rarity])
	elif rarity.is_empty():
		item = LootRoller.random_item(level)
	else:
		return "!Rarity: common, magic, rare or legendary"
	if item == null or not party.add(item):
		return "!Nothing to give, or the bag is full"
	return "In the bag: %s (item level %d)" % [item.display_name, item.item_level]


func _cmd_spawn(args: PackedStringArray) -> String:
	var registry := _registry()
	if registry == null or args.is_empty():
		return "!spawn <unit> [count] [team]"
	var path := UNITS + args[0] + ".tres"
	if not ResourceLoader.exists(path):
		return "!No unit %s (Tab lists them)" % args[0]
	var definition: UnitDefinition = load(path)
	var count := clampi(args[1].to_int(), 1, 100) if args.size() > 1 else 1
	var team := args[2].to_int() if args.size() > 2 else ENEMY_TEAM
	var at := _cursor()
	var spawned := 0
	for i in count:
		var spot := at + Vector3(cos(TAU * i / count), 0, sin(TAU * i / count)) * (0.0 if count == 1 else 1.0 + count * 0.15)
		var handle := registry.spawn_neutral(definition, spot, randf() * TAU, null, 1.0, true) if team == UnitRegistry.NEUTRAL_TEAM \
				else registry.spawn_npc(definition, team, spot, _spawner(team))
		if handle != UnitRegistry.NONE:
			spawned += 1
	return "Spawned %d %s (team %d)" % [spawned, definition.display_name, team]


func _cmd_kill(args: PackedStringArray) -> String:
	var radius := args[0].to_float() if not args.is_empty() and args[0].is_valid_float() else 8.0
	return "Killed %d" % _kill_enemies(_cursor(), radius)


func _cmd_killall(_args: PackedStringArray) -> String:
	return "Killed %d" % _kill_enemies(Vector3.ZERO, INF)


func _cmd_tp(_args: PackedStringArray) -> String:
	var heroes := _heroes()
	for i in heroes.size():
		heroes[i].teleport(_cursor() + Vector3(i * 1.5, 0, 0))
	return "Moved %d" % heroes.size()


func _cmd_flag(args: PackedStringArray) -> String:
	if args.is_empty():
		return "!flag <name> [0]"
	var value := args.size() < 2 or args[1] != "0"
	Campaign.current.set_story_flag(StringName(args[0]), value)
	return "%s %s" % [args[0], "set" if value else "cleared"]


func _cmd_flags(_args: PackedStringArray) -> String:
	var story: Dictionary = Campaign.current.flags.get("story", {})
	return ", ".join(PackedStringArray(story.keys())) if not story.is_empty() else "No story flags"


func _cmd_quest(_args: PackedStringArray) -> String:
	var lines := PackedStringArray()
	for quest: Quest in get_tree().get_nodes_in_group(Quest.GROUP):
		var steps := quest.steps()
		var at := steps.find(quest.current)
		var state := "done" if quest.done else ("step %d/%d: %s" % [at + 1, steps.size(), quest.current.objective]
				if quest.is_running() and quest.current != null else "not started")
		lines.append("%s (%s): %s" % [quest.title, quest.name, state])
	return "\n".join(lines) if not lines.is_empty() else "No quests on this map"


func _cmd_step(args: PackedStringArray) -> String:
	var wanted := " ".join(args).to_lower()
	for quest: Quest in get_tree().get_nodes_in_group(Quest.GROUP):
		if not quest.is_running() or quest.current == null:
			continue
		if not wanted.is_empty() and not (quest.title.to_lower().contains(wanted) or String(quest.name).to_lower().contains(wanted)):
			continue
		var objective := quest.current.objective
		quest.current.complete()
		return "Done: %s (%s)" % [objective, quest.title]
	return "!No running quest" + (" matching " + wanted if not wanted.is_empty() else "")


func _cmd_skip(_args: PackedStringArray) -> String:
	var skipped := 0
	for scene: StoryScene in get_tree().current_scene.find_children("*", "StoryScene", true, false) if get_tree().current_scene else []:
		if scene.playing:
			scene.skip()
			skipped += 1
	return "Skipped %d scene%s" % [skipped, "" if skipped == 1 else "s"]


func _cmd_map(args: PackedStringArray) -> String:
	if args.is_empty():
		return "!map <map> [arrival]"
	var path := _map_path(args[0])
	if path.is_empty():
		return "!No map %s (maps lists them)" % args[0]
	Campaign.current.travel(path, args[1] if args.size() > 1 else "")
	return "Travelling to " + path


func _cmd_maps(_args: PackedStringArray) -> String:
	return ", ".join(_map_names())


func _cmd_time(args: PackedStringArray) -> String:
	if args.is_empty() or not args[0].is_valid_float() or args[0].to_float() <= 0.0:
		return "Game speed: %s" % Engine.time_scale
	var speed := args[0].to_float()
	Engine.time_scale = speed
	Engine.physics_ticks_per_second = roundi(60.0 * maxf(speed, 1.0))  # each physics step stays 1/60 of a game second
	Engine.max_physics_steps_per_frame = maxi(8, roundi(speed * 1.5))
	return "Game speed: %s" % speed


func _cmd_tod(args: PackedStringArray) -> String:
	if args.is_empty() or not TimeOfDay.PRESETS.has(StringName(args[0])):
		return "!tod <%s>" % "|".join(PackedStringArray(TimeOfDay.PRESETS.keys()))
	TimeOfDay.apply(get_tree().current_scene, StringName(args[0]))
	return "It's " + args[0]


func _cmd_fog(_args: PackedStringArray) -> String:
	var fog := FogOfWar.current
	if fog == null:
		return "!No fog on this map"
	fog.enabled = not fog.enabled
	return "Fog of war " + ("on" if fog.enabled else "off")


func _cmd_exec(args: PackedStringArray) -> String:
	if args.is_empty():
		return "!exec <preset>: " + ", ".join(_files(PRESETS, ".txt"))
	var file := FileAccess.open(PRESETS + args[0] + ".txt", FileAccess.READ)
	if file == null:
		return "!No preset %s" % args[0]
	for line in file.get_as_text().split("\n", false):
		line = line.get_slice("#", 0).strip_edges()
		if not line.is_empty():
			run(line)
	return ""


# --- The map ---------------------------------------------------------------------

func _registry() -> UnitRegistry:
	return get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry


func _party() -> PartyInventory:
	return get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory


func _heroes() -> Array[Unit]:
	var party := _party()
	if party == null:
		var none: Array[Unit] = []
		return none
	return party.heroes()


## Where the mouse points on the ground (the party's first hero when there's no commander).
func _cursor() -> Vector3:
	var party := _party()
	if party != null and party.commander != null:
		return party.commander.trace_position
	var heroes := _heroes()
	return heroes[0].global_position if not heroes.is_empty() else Vector3.ZERO


## The level rolled items get by default: the party's best hero's.
func _level() -> int:
	var best := 1
	for hero in _heroes():
		best = maxi(best, hero.level)
	return best


## A hidden, inactive spawner of `team` on this map, for `spawn`.
func _spawner(team: int) -> CreepSpawner:
	if _spawners.has(team) and is_instance_valid(_spawners[team]):
		return _spawners[team]
	var spawner := CreepSpawner.new()
	spawner.name = "ConsoleSpawner%d" % team
	spawner.team = team
	spawner.active = false
	get_tree().current_scene.add_child(spawner)
	_spawners[team] = spawner
	return spawner


func _kill_enemies(around: Vector3, radius: float) -> int:
	var registry := _registry()
	if registry == null:
		return 0
	var killed := 0
	for handle in registry.handles():
		if not registry.is_alive(handle) or not UnitRegistry.are_enemies(registry.team_of(handle), registry.player_team):
			continue
		var at := registry.position_of(handle)
		if radius == INF or Vector2(at.x - around.x, at.z - around.z).length() <= radius:
			registry.kill(handle)
			killed += 1
	return killed


## "vigil", "story/vigil" or a full path: the map's scene, or "".
func _map_path(map_name: String) -> String:
	if map_name.begins_with("res://"):
		return map_name if ResourceLoader.exists(map_name) else ""
	for candidate in [MAPS + map_name + ".tscn", MAPS + "story/" + map_name + ".tscn"]:
		if ResourceLoader.exists(candidate):
			return candidate
	return ""


func _map_names() -> PackedStringArray:
	var names := _files(MAPS, ".tscn")
	for story_map in _files(MAPS + "story/", ".tscn"):
		names.append(story_map)
	names.erase("story_template")
	return names


## The names (without `extension`) of the files in `folder`; with `recurse`, "sub/name" for those below it.
## Resources through ResourceLoader (it sees them in an export too); plain text (presets) straight off the disk.
func _files(folder: String, extension: String, recurse := false) -> PackedStringArray:
	var names := PackedStringArray()
	var entries := ResourceLoader.list_directory(folder) if extension != ".txt" else DirAccess.get_files_at(folder)
	for entry in entries:
		if entry.ends_with("/"):
			if recurse:
				for inner in _files(folder + entry, extension, true):
					names.append(entry + inner)
		elif entry.ends_with(extension):
			names.append(entry.trim_suffix(extension))
	return names


# --- Completion and history ---------------------------------------------------

func _complete() -> void:
	if _completion_at < 0:
		_completion_base = _line.text
		_completions = _candidates(_completion_base)
		if _completions.is_empty():
			return
		if _completions.size() > 1:
			_print("  ".join(_completions.slice(0, 60)) + ("  ..." if _completions.size() > 60 else ""), OUTPUT_COLOR)
	_completion_at = (_completion_at + 1) % _completions.size()
	var words := _completion_base.split(" ")
	words[words.size() - 1] = _completions[_completion_at]
	_line.text = " ".join(words) + (" " if _completions.size() == 1 else "")
	_line.caret_column = _line.text.length()
	if _completions.size() == 1:
		_completion_at = -1


func _candidates(text: String) -> PackedStringArray:
	var command := text.get_slice(";", text.count(";")).strip_edges(true, false)
	var words := command.split(" ")
	var prefix := words[words.size() - 1]
	var options := PackedStringArray()
	if words.size() == 1:
		options = PackedStringArray(COMMANDS.keys())
	else:
		match [words[0].to_lower(), words.size()]:
			["give", 2]:
				options = _files(ITEMS, ".tres", true)
			["give", 3], ["loot", 3]:
				options = PackedStringArray(RARITIES.keys())
			["spawn", 2]:
				options = _files(UNITS, ".tres", true)
			["map", 2]:
				options = _map_names()
			["flag", 2]:
				options = PackedStringArray(Campaign.current.flags.get("story", {}).keys())
			["tod", 2]:
				options = PackedStringArray(TimeOfDay.PRESETS.keys())
			["exec", 2]:
				options = _files(PRESETS, ".txt")
			["help", 2]:
				options = PackedStringArray(COMMANDS.keys())
	var matches := PackedStringArray()
	for option in options:
		if option.begins_with(prefix):
			matches.append(option)
	matches.sort()
	return matches


func _walk_history(step: int) -> void:
	if _history.is_empty():
		return
	_history_at = clampi(_history_at + step, 0, _history.size())
	_line.text = _history[_history_at] if _history_at < _history.size() else ""
	_line.caret_column = _line.text.length()


func _on_submitted(text: String) -> void:
	_line.clear()
	_completion_at = -1
	if text.strip_edges().is_empty():
		return
	if _history.is_empty() or _history[_history.size() - 1] != text:
		_history.append(text)
		if _history.size() > MAX_HISTORY:
			_history = _history.slice(_history.size() - MAX_HISTORY)
		_save_history()
	_history_at = _history.size()
	run(text)


func _load_history() -> void:
	var file := FileAccess.open(HISTORY_FILE, FileAccess.READ)
	if file != null:
		_history = file.get_as_text().split("\n", false)
	_history_at = _history.size()


func _save_history() -> void:
	var file := FileAccess.open(HISTORY_FILE, FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(_history))


# --- The panel ----------------------------------------------------------------

func _print(text: String, color: Color) -> void:
	print(text)
	_log.push_color(color)
	_log.add_text(text + "\n")
	_log.pop()


func _build() -> void:
	_panel.anchor_right = 1.0
	_panel.anchor_bottom = 0.45
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.88)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	_panel.add_theme_stylebox_override(&"panel", style)
	add_child(_panel)
	var column := VBoxContainer.new()
	_panel.add_child(column)
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["monospace"])
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.focus_mode = Control.FOCUS_NONE
	_log.add_theme_font_override(&"normal_font", font)
	_log.add_theme_font_size_override(&"normal_font_size", 14)
	column.add_child(_log)
	_line.placeholder_text = "help, then Tab to complete; ` or Esc closes"
	_line.add_theme_font_override(&"font", font)
	_line.add_theme_font_size_override(&"font_size", 15)
	_line.text_submitted.connect(_on_submitted)
	_line.keep_editing_on_text_submit = true
	column.add_child(_line)
	_print("Developer console. help lists the commands.", ECHO_COLOR)
