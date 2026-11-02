class_name Campaign
extends Node

## The run across maps (SAVES.md); an autoload ("GameCampaign"), reached as Campaign.current. It carries the party (heroes,
## their progress and equipment, the shared bag) from map to map, remembers campaign
## flags (items already picked up), and writes and reads save files.
##
## A save is the whole map's state, the keyframe noh's server would send a client joining
## mid-game, plus the campaign's own data, all as plain values (SaveCodec), so the same
## data can later go over the network. Solo, the player saves anywhere (F5, F6 loads);
## online, only the host saves, at checkpoints (travelling between maps).
##
## Against crashes: solo, every RECOVERY_TIME of play the game quietly writes RECOVERY_SLOT. A
## clean exit (quitting, or back to the title) deletes the one this run wrote, so it's only there
## after a crash, where Continue on the title screen picks it up as the newest save; a run that
## starts after a crash and quits without playing leaves it be. A newer save, another save
## loaded, or a new game replace it. Every save is written to a
## temporary file renamed over the old one, so a crash while writing leaves the old one whole.

signal saved(slot: String)
signal loaded(slot: String)
## A story flag was set or cleared (StoryGate listens).
signal story_flag_changed(flag: StringName)

## The running campaign (the autoload). A static, not the autoload's name, so scripts
## using it also compile where autoloads aren't registered (--check-only, test drivers).
static var current: Campaign
## Where saves go: SAVE_DIR, or TEST_SAVE_DIR for the tests (support.speed_up switches).
static var save_dir := SAVE_DIR

const SAVE_DIR := "user://saves"
const TEST_SAVE_DIR := "user://test_saves"  ## the tests' saves (they delete theirs), apart from the player's
const EXTENSION := ".save"
const FORMAT := "nsst-save"
const VERSION := 1  ## raise when the layout changes, and teach _migrate() the old one
const QUICK_SLOT := "quicksave"
const AUTO_SLOT := "autosave"
const RECOVERY_SLOT := "recovery"
const RECOVERY_TIME := 30.0  ## seconds of play between crash-recovery saves
const TITLE_SCENE := "res://scenes/ui/title.tscn"
const FIRST_MAP := "res://scenes/maps/story/broken_road.tscn"  ## where New Game starts: the prologue (generated: tools/story/make_story_maps.gd) and its tutorial

## A multiplayer session: only the host saves, and only at checkpoints.
var online := false
var is_host := true
## The run's flags, e.g. {"taken": {map path: [node paths of items picked up]}}.
var flags := {}
var play_time := 0.0

var _map: Node  ## the running map's root (scripts/main.gd)
var _pending := {}  ## what the next map loads: {"world": ...} or {"party": ..., "arrival": ...}
var _pending_slot := ""
var _checkpoint := false  ## a save right now counts as a checkpoint (arriving on a map)
var _menu := GameMenu.new()
var _loading := LoadingScreen.new()
var _loading_path := ""  ## the scene being loaded in the background
var _recovery_timer := RECOVERY_TIME
var _recovery_task := -1  ## the WorkerThreadPool task writing the last recovery save
var _recovery_ours := false  ## this run wrote the recovery save (not a crashed one before it)


func _init() -> void:
	current = self  # as soon as the autoload exists, before it enters the tree


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_menu)
	add_child(_loading)


func _process(delta: float) -> void:
	if _map != null and not get_tree().paused:
		play_time += delta
		_recovery_timer -= delta
		if _recovery_timer <= 0.0 and _loading_path.is_empty():
			_recovery_timer = RECOVERY_TIME
			_save_recovery()
	if _loading_path.is_empty():
		return
	match ResourceLoader.load_threaded_get_status(_loading_path):
		ResourceLoader.THREAD_LOAD_LOADED:
			var scene := ResourceLoader.load_threaded_get(_loading_path) as PackedScene
			_loading_path = ""
			get_tree().change_scene_to_packed(scene)
			_hide_loading.call_deferred()
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_error("Couldn't load %s" % _loading_path)
			_loading_path = ""
			_loading.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"rts_quick_save"):
		report(save_game(QUICK_SLOT), "Game saved")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"rts_quick_load"):
		var error := load_game(QUICK_SLOT)
		if not error.is_empty():
			report(error, "")
		get_viewport().set_input_as_handled()


# --- Maps ----------------------------------------------------------------------

## Called by every map's root once its own nodes are ready. Restores a loaded save or
## brings in the travelling party; returns false when the map should start fresh.
func enter_map(map: Node) -> bool:
	_map = map
	map.tree_exiting.connect(func() -> void:
		if _map == map:
			_map = null)
	var pending := _pending
	_pending = {}
	map.remove_taken_pickups(taken_pickups(map.scene_file_path))
	if pending.has("world"):
		map.restore_world(pending.world)
		loaded.emit(_pending_slot)
		return true
	if pending.has("party"):
		map.receive_party(pending.party, pending.get("arrival", ""))
		var left: Dictionary = flags.get("left_items", {})
		map.place_loot_at_entrance(left.get(map.scene_file_path, []), pending.get("arrival", ""))
		left.erase(map.scene_file_path)
		_checkpoint = true
		save_game.call_deferred(AUTO_SLOT)  # arriving on a map is a checkpoint
		return true
	return false


## The whole party reached a checkpoint (Checkpoint): the game autosaves, also online.
func reach_checkpoint() -> void:
	_checkpoint = true
	report(save_game(AUTO_SLOT, "Checkpoint"), "Checkpoint: game saved")


## Starts a new run on `map`.
func new_game(map_path := FIRST_MAP) -> void:
	flags = {}
	play_time = 0.0
	_pending = {}
	_end_recovery(true)  # a crash from here on shouldn't bring back the run before
	go_to(resolve_map(map_path))  # flags are fresh: every new game rolls its maps again


## A wild map has several generated layouts (tools/story/make_story_maps.gd: broken_road.tscn, broken_road_v1.tscn,
## ...): the first time the campaign goes to it, one is picked at random and kept for the campaign (saves and
## return trips find the same map); a new game rolls them all again. Maps with no layouts (the village) are as they are.
func resolve_map(path: String) -> String:
	var chosen: Dictionary = flags.get_or_add("map_variants", {})
	if chosen.has(path):
		return chosen[path]
	var options: Array[String] = [path]
	var stem := path.trim_suffix(".tscn")
	var number := 1
	while ResourceLoader.exists("%s_v%d.tscn" % [stem, number]):
		options.append("%s_v%d.tscn" % [stem, number])
		number += 1
	chosen[path] = options.pick_random()
	return chosen[path]


## Whether `path` is the first map, or one of its layouts.
static func is_first_map(path: String) -> bool:
	return path == FIRST_MAP or path.begins_with(FIRST_MAP.trim_suffix(".tscn") + "_v")


func quit_to_title() -> void:
	_pending = {}
	_end_recovery()
	go_to(TITLE_SCENE)


## Quitting the game (or the tests ending) is a clean exit: no crash to recover from.
func _exit_tree() -> void:
	_end_recovery()


## The in-game menu (Esc when nothing is left to cancel).
func open_menu() -> void:
	if _map != null:
		_menu.open()


## Changes the scene behind the loading screen; the scene loads on another thread.
func go_to(scene_path: String) -> void:
	get_tree().paused = false
	_loading.visible = true
	_loading_path = scene_path
	if ResourceLoader.load_threaded_request(scene_path) != OK:
		_loading_path = ""
		get_tree().change_scene_to_file(scene_path)
		_hide_loading.call_deferred()


func _hide_loading() -> void:
	await get_tree().process_frame  # the new scene has drawn once
	_loading.visible = false


## Leaves the running map for `map_path`, taking the party along; it arrives at the
## marker named `arrival` (or the map's hero start).
func travel(map_path: String, arrival := "") -> void:
	if _map == null:
		return
	# Loot left lying here waits at the entrance when the party comes back
	var left: Dictionary = flags.get_or_add("left_items", {})
	left[_map.scene_file_path] = _map.loot_left_behind()
	_pending = {"party": _map.save_party(), "arrival": arrival}
	go_to(resolve_map(map_path))


## Remembers that the item pickup `pickup` was taken, so it stays gone on this map.
func mark_taken(pickup: Node) -> void:
	if _map == null:
		return
	var taken: Dictionary = flags.get_or_add("taken", {})
	var list: Array = taken.get_or_add(_map.scene_file_path, [])
	list.append(str(_map.get_path_to(pickup)))


func taken_pickups(map_path: String) -> Array:
	return flags.get("taken", {}).get(map_path, [])


## Remembers that `node` (a chest) was opened, so it stays open on this map.
func mark_opened(node: Node) -> void:
	if _map == null:
		return
	var opened: Dictionary = flags.get_or_add("opened", {})
	var list: Array = opened.get_or_add(_map.scene_file_path, [])
	var path := str(_map.get_path_to(node))
	if not list.has(path):
		list.append(path)


func is_opened(node: Node) -> bool:
	var map := node.owner if node.owner != null else node.get_tree().current_scene
	if map == null:
		return false
	return flags.get("opened", {}).get(map.scene_file_path, []).has(str(map.get_path_to(node)))


# --- Story -----------------------------------------------------------------------

## Story flags: named facts about the story so far ("met_the_innkeeper"), set by quest steps
## or scripts, checked by quest steps; they last across maps and are saved.
func set_story_flag(flag: StringName, value := true) -> void:
	var story: Dictionary = flags.get_or_add("story", {})
	if value:
		story[str(flag)] = true
	else:
		story.erase(str(flag))
	story_flag_changed.emit(flag)


func has_story_flag(flag: StringName) -> bool:
	return flags.get("story", {}).has(str(flag))


## A quest's saved progress on this map: {step, done, kills}; {} when it never started.
func quest_state(quest: Node) -> Dictionary:
	var map := quest.owner if quest.owner != null else quest.get_tree().current_scene
	if map == null:
		return {}
	return flags.get("quests", {}).get(map.scene_file_path, {}).get(str(map.get_path_to(quest)), {})


func set_quest_state(quest: Node, state: Dictionary) -> void:
	var map := quest.owner if quest.owner != null else quest.get_tree().current_scene
	if map == null:
		return
	var quests: Dictionary = flags.get_or_add("quests", {})
	var on_map: Dictionary = quests.get_or_add(map.scene_file_path, {})
	on_map[str(map.get_path_to(quest))] = state


# --- Save files ----------------------------------------------------------------

## Why saving isn't possible right now, or "".
func save_refusal() -> String:
	if _map == null:
		return "Nothing to save"
	if online and not is_host:
		return "Only the host saves in multiplayer"
	if online and not _checkpoint:
		return "In multiplayer the game saves at checkpoints"
	if StoryScene.active > 0:
		return "Not in the middle of a scene"
	return ""


## Writes the running map and the campaign to `slot`; returns "" or why it didn't.
func save_game(slot: String, label := "") -> String:
	var refusal := save_refusal()
	_checkpoint = false
	if not refusal.is_empty():
		return refusal
	var error := _write(_path_of(slot), _header(slot, label), _body())
	if error != OK:
		return "Couldn't write the save: %s" % error_string(error)
	if slot != RECOVERY_SLOT:
		_end_recovery(true)  # this save is newer
	saved.emit(slot)
	return ""


## What the save list shows of a save: slot, label, map, time, party.
func _header(slot: String, label := "") -> Dictionary:
	var heroes := []
	for unit: Unit in _map.party_units():
		heroes.append({"name": unit.definition.display_name, "level": unit.level})
	return {
		"format": FORMAT,
		"version": VERSION,
		"slot": slot,
		"label": label if not label.is_empty() else (_map.map_name if not _map.map_name.is_empty() else str(_map.name)),
		"saved_at": Time.get_unix_time_from_system(),
		"map": _map.scene_file_path,
		"play_time": play_time,
		"heroes": heroes,
		"online": online,
	}


## The save itself: the campaign and the running map's whole state, as plain values.
func _body() -> Dictionary:
	return {
		"campaign": {"flags": flags.duplicate(true), "play_time": play_time},
		"world": _map.save_world(),
	}


## Writes a save file: into a temporary file first, then renamed over `path`, so a crash while
## writing leaves the last save whole. Runs on worker threads too (recovery saves).
static func _write(path: String, header: Dictionary, body: Dictionary) -> Error:
	DirAccess.make_dir_recursive_absolute(save_dir)
	var temporary := path + ".part"
	var file := FileAccess.open_compressed(temporary, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return FileAccess.get_open_error()
	file.store_var(header)
	file.store_var(body)
	file.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path))


## The crash-recovery save: the state is taken here (a few milliseconds on Caldavar); it's
## compressed and written on a worker thread while the game goes on.
func _save_recovery() -> void:
	if _map == null or online:
		return
	if _recovery_task >= 0:
		if not WorkerThreadPool.is_task_completed(_recovery_task):
			return  # the last one is still being written
		WorkerThreadPool.wait_for_task_completion(_recovery_task)
	_recovery_task = WorkerThreadPool.add_task(_write.bind(_path_of(RECOVERY_SLOT), _header(RECOVERY_SLOT), _body()),
			false, "Crash-recovery save")
	_recovery_ours = true


## The run is in a safe place (a clean exit, a newer save, another run): the recovery save goes,
## if this run wrote it, or `always` (the player chose another state).
func _end_recovery(always := false) -> void:
	if _recovery_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_recovery_task)
		_recovery_task = -1
	_recovery_timer = RECOVERY_TIME
	if (always or _recovery_ours) and FileAccess.file_exists(_path_of(RECOVERY_SLOT)):
		delete_save(RECOVERY_SLOT)
	_recovery_ours = false


## Loads `slot`: its map starts over and takes the saved state. Returns "" or why not.
func load_game(slot: String) -> String:
	var file := FileAccess.open_compressed(_path_of(slot), FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return "No save called %s" % slot
	var header: Variant = file.get_var()
	var body: Variant = file.get_var()
	file.close()
	if not header is Dictionary or header.get("format") != FORMAT or not body is Dictionary:
		return "%s isn't a save file" % slot
	if header.version > VERSION:
		return "%s was saved by a newer version of the game" % slot
	body = _migrate(body, header.version)
	if slot != RECOVERY_SLOT:
		_end_recovery(true)  # going back to an older save: a crash from here shouldn't bring back the newer state
	flags = body.campaign.flags
	play_time = body.campaign.play_time
	_pending = {"world": body.world}
	_pending_slot = slot
	go_to(header.map)
	return ""


## Every save's header (slot, label, map, time, heroes), newest first.
func list_saves() -> Array[Dictionary]:
	var headers: Array[Dictionary] = []
	if not DirAccess.dir_exists_absolute(save_dir):
		return headers
	for file_name in DirAccess.get_files_at(save_dir):
		if not file_name.ends_with(EXTENSION):
			continue
		var file := FileAccess.open_compressed(save_dir.path_join(file_name), FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
		if file == null:
			continue
		var header: Variant = file.get_var()
		if header is Dictionary and header.get("format") == FORMAT:
			headers.append(header)
	headers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.saved_at > b.saved_at)
	return headers


func delete_save(slot: String) -> void:
	DirAccess.remove_absolute(_path_of(slot))


## Brings an older save's data up to the current layout (nothing to do at version 1).
func _migrate(body: Dictionary, _from_version: int) -> Dictionary:
	return body


func _path_of(slot: String) -> String:
	return save_dir.path_join(slot.validate_filename() + EXTENSION)


## Shows `error`, or `success` when there was none, in the running map's message line.
func report(error: String, success: String) -> void:
	if _map == null:
		return
	var commander: Commander = _map.get_node(^"Commander")
	if error.is_empty():
		commander.show_message(success, PartyInventory.GOOD_NEWS)
	else:
		commander.show_error(error)
