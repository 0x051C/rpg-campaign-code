extends SceneTree
## Builds the first campaign's maps (STORY.md) as playable placeholders to fill in:
##
## - scenes/maps/story_template.tscn: a map's setup without content (camera, HUD, registry, fog,
##   party), on Caldavar's tileset. The story maps inherit it: change the HUD there, once.
## - scenes/maps/story/*.tscn: the six maps after the hub (three jobs, Briar's Hollow, the lodge,
##   the finale), each with a terrain of its own, placeholder buildings and props, the people of
##   the story, its quest, scenes and exits.
## - A "Story" node added to the prologue and the village: the prologue's quest and scenes, the
##   hub's jobs, the stranger, and the exits that tie the maps together.
## - data/units/story/*.tres: the story's units (Ser Aldith, Nell, Tamsin, the Risen, the ghoul
##   mother, the weirs, Corwin, the villagers); data/meals/*.tres: the inn's suppers;
##   data/items/story_start_kit.tres: what Maren carries off the carriage.
## - scenes/maps/story/pit.tscn: the Pit, a last-hitting challenge for the night's gold.
##
## Everything that already exists is left alone, so it never overwrites work done in the editor:
##   godot --headless --path . --script res://tools/story/make_story_maps.gd
##   ... -- --rewrite           rebuilds the template, the story maps and the units too
##   ... -- --rewrite-story     replaces the prologue's and the village's Story nodes too

const TEMPLATE := "res://scenes/maps/story_template.tscn"
const SOURCE := "res://scenes/maps/village.tscn"  ## the template is the village without the village
const PROLOGUE := "res://scenes/maps/prologue.tscn"
const VILLAGE := "res://scenes/maps/village.tscn"
const VIGIL := "res://scenes/maps/story/vigil.tscn"
const DEBTS := "res://scenes/maps/story/debts.tscn"
const HUNT := "res://scenes/maps/story/hunt.tscn"
const HOLLOW := "res://scenes/maps/story/hollow.tscn"
const LODGE := "res://scenes/maps/story/lodge.tscn"
const FINALE := "res://scenes/maps/story/finale.tscn"
const PIT := "res://scenes/maps/story/pit.tscn"
## The prologue as a generated wild map (the road north, its stops placed by AreaPlan): New Game starts here.
## prologue.tscn, the hand-built one, stays as it is (and is where the presets come from).
const ROAD := "res://scenes/maps/story/broken_road.tscn"
const PRESETS := "res://scenes/presets/prologue/"  ## tools/presets/extract_presets.gd, from prologue.tscn
const TILESET := "res://data/terrain/caldavar_tileset.tres"
const UNITS := "res://data/units/story/"
const PROP := "res://assets/environment/hon/props/%s/%s.glb"
const MAP_PROP := preload("res://scripts/map/map_prop.gd")
const AreaPlan := preload("res://tools/story/area_plan.gd")
## What fills a big map's free cells (DIRECTION.md 5), by biome: pieces and how often, and who lives in
## them (towards the goal, more of them and more champions).
const BIOMES := {
	"wood": {"pieces": {"woods": 6, "rocks": 2, "graves": 1, "campsite": 1, "clearing": 2, "relic": 1},
		"monsters": ["ghoul", "ghoul", "skeleton_minion"], "trees": ["fir_1", "fir_2", "fir_3", "pine_1", "pine_2"]},
	"hollow": {"pieces": {"ruin": 3, "house": 3, "graves": 2, "field": 2, "woods": 2, "campsite": 1},
		"monsters": ["skeleton_minion", "skeleton_minion", "zealot", "ghoul"], "trees": ["dry_tree_1", "dry_tree_2", "birch_1", "fir_3"],
		"scenery": ["woods", "ruin", "rocks", "field", "graves"]},
	"road": {"pieces": {"woods": 5, "rocks": 2, "graves": 2, "campsite": 1, "clearing": 2, "field": 1, "relic": 2}, "packs": 0.25,
		"monsters": ["husk", "husk", "ghoul"], "trees": ["fir_1", "fir_2", "pine_1", "pine_2", "dry_tree_1"]},
	"lanes": {"pieces": {"house": 5, "ruin": 2, "field": 2, "campsite": 2, "clearing": 1},
		"monsters": ["thug"], "trees": ["oak_1", "oak_2", "beech_1", "birch_2"],
		"scenery": ["woods", "field", "house", "clearing"]},
}

var _rewrite := false
var _variant := 0  ## 0: the baked map; 1..: another layout of it (seed and file name change)
var _variants := 6  ## --variants=N: how many layouts of each wild map there are (0 is the first)
var _rewrite_story := false
var _tileset: TerrainTileset
var _root: Node3D
var _story: Node3D
var _units := {}
var _meals: Array[Meal] = []
var _plaster: Material = load("res://data/materials/plaster.tres")
var _timber: Material = load("res://data/materials/timber.tres")
var _thatch: Material = load("res://data/materials/thatch.tres")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_rewrite = args.has("--rewrite")
	_rewrite_story = args.has("--rewrite-story") or _rewrite
	for arg in args:
		if arg.begins_with("--variants="):
			_variants = arg.get_slice("=", 1).to_int()
	_tileset = load(TILESET)
	DirAccess.make_dir_recursive_absolute("res://scenes/maps/story")
	DirAccess.make_dir_recursive_absolute("res://data/terrain/story")
	DirAccess.make_dir_recursive_absolute(UNITS)
	_make_units()
	_make_meals()
	_make_template()
	_make_vigil()
	_make_debts()
	_make_hunt()
	_make_hollow()
	_make_lodge()
	_make_finale()
	_make_pit()
	_make_road()
	# More layouts of the wild maps (Campaign.resolve_map picks one per new game): same story, other seeds
	for v in range(1, _variants):
		_variant = v
		_make_road()
		_make_hunt()
		_make_hollow()
		_make_debts()
	_variant = 0
	_story_prologue()
	_story_village()
	quit()


# --- The story's units ---------------------------------------------------------

func _make_units() -> void:
	# HoN's neutrals stand in for the story's beasts and cultists (tools/noh/make_noh_prefabs.py)
	var werebeast: PackedScene = load("res://scenes/characters/hon/n_werebeast.tscn")
	var enchanter: PackedScene = load("res://scenes/characters/hon/n_werebeast_enchanter.tscn")
	var robed: PackedScene = load("res://scenes/characters/hon/bad_range.tscn")
	# The recruits: the classes that exist, on their own (fan-mod) models, their clips and voices
	_unit("aldith", "res://data/units/knight.tres", {"display_name": "Ser Aldith"})
	_unit("nell", "res://data/units/rogue_hero.tres", {"display_name": "Nell"})
	# Tamsin's own kit (STORY.md 6): Burning Arrows, Falling Stars, Seeking Arrows, the Hawk; her reach grows with Strength
	var ranger: UnitDefinition = load("res://data/units/ranger.tres")
	var tamsin_passives: Array = ranger.passives.duplicate()
	tamsin_passives.append(load("res://data/passives/tamsin_eagle_eye.tres"))
	var tamsin_kit := {"abilities": [load("res://data/abilities/tamsin_burning_arrows.tres"), load("res://data/abilities/tamsin_falling_stars.tres"),
			load("res://data/abilities/tamsin_seeking_arrows.tres"), load("res://data/abilities/tamsin_hawk.tres")], "passives": tamsin_passives}
	_unit("tamsin", "res://data/units/ranger.tres", {"display_name": "Tamsin"}.merged(tamsin_kit))
	# The hero left behind comes back as one of the Risen: the same model, an enemy's numbers
	# Hand-tuned bosses keep their numbers: a level set here means a map never levels them again
	_unit("risen_aldith", "res://data/units/knight.tres", {"display_name": "Risen Ser Aldith", "max_health": 1400.0,
			"attack_damage": 45.0, "bounty_experience": 200.0, "aggro_range": 9.0, "monster_level": 6})
	_unit("risen_nell", "res://data/units/rogue_hero.tres", {"display_name": "Risen Nell", "max_health": 1000.0,
			"attack_damage": 50.0, "bounty_experience": 200.0, "aggro_range": 9.0, "monster_level": 6})
	_unit("risen_tamsin", "res://data/units/ranger.tres", {"display_name": "Risen Tamsin", "max_health": 900.0,
			"attack_damage": 45.0, "bounty_experience": 200.0, "aggro_range": 10.0, "monster_level": 6}.merged(tamsin_kit))
	var lightbrand: ItemDefinition = load("res://data/items/lightbrand.tres")
	var firebrand: ItemDefinition = load("res://data/items/firebrand.tres")
	_unit("ghoul_mother", "res://data/units/skeleton_warrior.tres", {"display_name": "Ghoul Mother", "model": enchanter,
			"max_health": 1600.0, "attack_damage": 40.0, "bounty_experience": 150.0, "monster_level": 3,
			"named_drops": [lightbrand], "named_drop_chance": 1.0})
	_unit("corwin_risen", "res://data/units/skeleton_mage.tres", {"display_name": "Corwin, the Gleaner", "max_health": 3500.0,
			"attack_damage": 55.0, "bounty_experience": 400.0, "monster_level": 7})
	# The Twin Brands' halves (DIRECTION.md 1, Dota's way): farmed from the kinds that carry them
	_unit("ghoul", "res://data/units/skeleton_rogue.tres", {"display_name": "Ghoul", "model": werebeast, "named_drops": [lightbrand],
			"named_drop_chance": 0.12})
	_unit("zealot", "res://data/units/skeleton_mage.tres", {"display_name": "Gleaner Zealot", "model": robed, "named_drops": [firebrand],
			"named_drop_chance": 0.2})
	# The road's dead, on HoN's models (phasing KayKit out): husks are the valley's farmers risen, a brute one of the Risen
	_unit("husk", "res://data/units/skeleton_minion.tres", {"display_name": "Husk", "model": load("res://scenes/characters/hon/n_skeleton.tscn")})
	_unit("risen_brute", "res://data/units/skeleton_warrior.tres", {"display_name": "Risen",
			"model": load("res://scenes/characters/hon/n_skeleton_boss.tscn")})
	# The farm's ledger: a book to read (lore)
	_unit("ledger", "res://data/units/skeleton_warrior.tres", {"display_name": "The farm's ledger",
			"model": load("res://assets/weapons/adventurers/spellbook_open.gltf"), "max_health": 25.0, "bounty_experience": 0.0,
			"attack_damage": 0.0, "move_speed": 0.0})
	# A weir: a ruin standing for it until there's a model; struck down, it breaks
	_unit("weir", "res://data/units/skeleton_warrior.tres", {"display_name": "Old Weir", "model": _prop_scene("ruins"),
			"max_health": 900.0, "armor": 4.0, "attack_damage": 0.0, "bounty_experience": 0.0, "move_speed": 0.0})
	# The farm's root cellar: a crate standing for it (the village kit's)
	_unit("cellar", "res://data/units/skeleton_warrior.tres", {"display_name": "The root cellar",
			"model": load("res://assets/environment/village/Prop_Crate.glb"), "attack_damage": 0.0, "move_speed": 0.0})
	# Something to look at: the open book (the prologue's ledger's model)
	_unit("clue", "res://data/units/skeleton_warrior.tres", {"display_name": "Something here",
			"model": load("res://assets/weapons/adventurers/spellbook_open.gltf"), "attack_damage": 0.0, "move_speed": 0.0})
	# Townsfolk: the modular characters (tools/assets/make_npcs.sh, scenes/characters/townsfolk), on the
	# numbers of the class they fight like
	for entry: Array in [["bede", "Acolyte Bede", "barbarian", "bede", {}], ["fenn", "Old Fenn", "barbarian", "fenn", {}],
			["hob", "Hob", "rogue", "hob", {}], ["corwin", "Corwin Hale", "barbarian", "corwin", {}],
			["jory", "Jory Wainwright", "skeleton_warrior", "jory", {}],  # one of the Faithful: dead, and still himself
			["thug", "Coyne's Man", "barbarian", "villager_man", {"aggro_range": 7.0, "max_health": 420.0, "attack_damage": 18.0,
				"bounty_experience": 40.0}],
			["chandler", "Mags the Chandler", "rogue", "mags", {}], ["pitmaster", "Bram Toller", "barbarian", "pitmaster", {}],
			["pedlar", "A pedlar", "rogue", "pedlar", {}], ["smith", "Tobias Cole", "barbarian", "warden", {}],
			["warden", "Road Warden", "barbarian", "warden", {"max_health": 300.0, "attack_damage": 14.0, "bounty_experience": 0.0}],
			["brann", "Brann", "barbarian", "brann", {}],
			["villager_man", "Villager", "rogue", "villager_man", {}], ["villager_woman", "Villager", "rogue", "villager_woman", {}],
			["villager_girl", "Villager", "rogue", "villager_girl", {}]]:
		var values: Dictionary = {"display_name": entry[1], "model": load("res://scenes/characters/townsfolk/%s.tscn" % entry[3])}
		values.merge(entry[4])
		_unit(entry[0], "res://data/units/%s.tres" % entry[2], values)


func _unit(id: String, from: String, values: Dictionary) -> void:
	var path := UNITS + id + ".tres"
	if FileAccess.file_exists(path) and not _rewrite:
		_units[id] = load(path)
		return
	var definition: UnitDefinition = (load(from) as UnitDefinition).duplicate()
	for key: String in values:
		if definition.get(key) is Array:
			(definition.get(key) as Array).assign(values[key])  # typed arrays (named_drops) keep their type
		else:
			definition.set(key, values[key])
	print("unit %s: %s" % [id, error_string(ResourceSaver.save(definition, path))])
	definition.take_over_path(path)
	_units[id] = definition


func _make_meals() -> void:
	DirAccess.make_dir_recursive_absolute("res://data/meals")
	for entry: Array in [
			["barley_stew", "Barley stew", "Thick and hot: +1.5 health regeneration a second until the next night.", 4, "St", Color(0.8, 0.6, 0.35),
				{Stats.Stat.HEALTH_REGEN: 1.5}],
			["smoked_trout", "Smoked trout", "From the millpond: +0.8 mana regeneration a second until the next night.", 5, "Tr", Color(0.55, 0.7, 0.85),
				{Stats.Stat.MANA_REGEN: 0.8}],
			["bread_and_ale", "Black bread and ale", "A soldier's supper: +2 Strength until the next night.", 4, "Al", Color(0.75, 0.55, 0.3),
				{Stats.Stat.STRENGTH: 2.0}],
			["honey_cakes", "Honey cakes", "Light on the feet: +0.3 movement speed until the next night.", 6, "Hc", Color(0.95, 0.8, 0.4),
				{Stats.Stat.MOVE_SPEED: 0.3}]]:
		var path := "res://data/meals/%s.tres" % entry[0]
		if FileAccess.file_exists(path) and not _rewrite:
			_meals.append(load(path))
			continue
		var meal := Meal.new()
		meal.display_name = entry[1]
		meal.description = entry[2]
		meal.price = entry[3]
		meal.icon_glyph = entry[4]
		meal.icon_color = entry[5]
		var bonuses: Dictionary[Stats.Stat, float] = {}
		bonuses.assign(entry[6])
		meal.bonuses = bonuses
		print("meal %s: %s" % [entry[0], error_string(ResourceSaver.save(meal, path))])
		meal.take_over_path(path)
		_meals.append(meal)
	var kit_path := "res://data/items/story_start_kit.tres"
	if not FileAccess.file_exists(kit_path) or _rewrite:
		var kit := ItemCatalog.new()
		kit.items.append(load("res://data/items/leather_cap.tres"))
		kit.items.append(load("res://data/items/mantle_of_intelligence.tres"))
		print("story kit: ", error_string(ResourceSaver.save(kit, kit_path)))


# --- The template ----------------------------------------------------------------

func _make_template() -> void:
	if FileAccess.file_exists(TEMPLATE) and not _rewrite:
		return
	var root: Node3D = load(SOURCE).instantiate()
	root.name = "StoryMap"
	root.set("map_name", "")
	var region: Node3D = root.get_node("NavigationRegion3D")
	for node in region.get_children():
		if node.name != "Terrain":
			node.free()
	# the village's own people, exits and Story (its quests, inn and givers): none of it belongs on a job's map
	for path in ["Villagers", "ToLane", "FromLane", "WellCheckpoint", "QuestGiver1", "Story"]:
		var node := root.get_node_or_null(path)
		if node != null:
			node.free()
	var terrain: Terrain = region.get_node("Terrain")
	terrain.tileset = _tileset
	terrain.data = _save_terrain("template", {"size": Vector2i(48, 48), "seed": 1, "ground": "g1_ground"})
	(root.get_node("HeroStart") as Node3D).position = Vector3(0, 0, 12)
	(root.get_node("HUD/Help") as CanvasItem).visible = false  # hidden, as in the prologue: the tutorial teaches instead
	var clock := TimeOfDay.new()
	root.add_child(clock)
	clock.name = "TimeOfDay"
	clock.preset = "day"
	var story := Node3D.new()
	root.add_child(story)
	story.name = "Story"
	for node in root.find_children("*", "", true, false):
		if node.owner == null:
			node.owner = root
	_save(root, TEMPLATE)


# --- Building blocks -------------------------------------------------------------

## Each map's monster level (DIRECTION.md 2): the jobs 2-3, the valley 5-7; the Pit 3.
const LEVELS := {"NightVigil": 2, "DebtsOfTheLiving": 2, "WhatHuntsTheHunters": 3, "BriarsHollow": 5, "GleanersLodge": 6,
		"RingOfWater": 7, "ThePit": 3, "TheBrokenRoad": 1}


func _begin(map_name: String, node_name: String, terrain: Dictionary, time: String, start: Vector3) -> void:
	_root = (load(TEMPLATE) as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_MAIN_INHERITED)
	_root.name = node_name
	(_root.get_node("UnitRegistry") as UnitRegistry).monster_level = LEVELS.get(node_name, 1)
	var extent := Rect2(-Vector2(terrain.size) * 0.5, Vector2(terrain.size))  # the view and the fog cover the whole map
	(_root.get_node("RTSCamera") as RTSCamera).bounds = extent
	_root.get_node("FogOfWar").set("bounds", extent)
	_root.set("map_name", map_name)
	(_root.get_node("NavigationRegion3D/Terrain") as Terrain).data = _save_terrain(node_name.to_snake_case() + ("" if _variant == 0 else "_v%d" % _variant), terrain)
	(_root.get_node("HeroStart") as Node3D).position = start
	(_root.get_node("TimeOfDay") as TimeOfDay).preset = time
	_story = _root.get_node("Story")


func _finish(path: String) -> void:
	_save(_root, path)


## `path` for the current layout: broken_road.tscn, broken_road_v2.tscn... (0 is the plain name).
func _variant_path(path: String) -> String:
	return path if _variant == 0 else path.trim_suffix(".tscn") + "_v%d.tscn" % _variant


func _exists(path: String) -> bool:
	if FileAccess.file_exists(path) and not _rewrite:
		print("kept ", path)
		return true
	return false


func _save(root: Node, path: String) -> void:
	for node in root.find_children("*", "", true, false):
		if node.owner == null:
			node.owner = root
	var packed := PackedScene.new()
	var packed_error := packed.pack(root)
	print("%s: pack %s, save %s" % [path, error_string(packed_error), error_string(ResourceSaver.save(packed, path))])
	root.free()


func _node(parent: Node, node: Node, node_name: String, at := Vector3.ZERO, yaw := 0.0) -> Node:
	parent.add_child(node)
	node.name = node_name
	if node is Node3D:
		(node as Node3D).position = at
		(node as Node3D).rotation.y = yaw
	node.owner = _root
	return node


func _group(parent: Node, node_name: String) -> Node3D:
	return _node(parent, Node3D.new(), node_name) as Node3D


func _marker(parent: Node, node_name: String, at: Vector3, yaw := 0.0) -> Marker3D:
	return _node(parent, Marker3D.new(), node_name, at, yaw) as Marker3D


func _npc(parent: Node, node_name: String, at: Vector3, yaw: float, unit: String, speaker: String, lines: Array,
		options := {}) -> NeutralSpawn:
	var npc := NeutralSpawn.new()
	npc.definition = _units[unit] if _units.has(unit) else load("res://data/units/%s.tres" % unit)
	if not lines.is_empty():
		var dialogue := Dialogue.new()
		dialogue.speaker = speaker
		dialogue.lines = PackedStringArray(lines)
		dialogue.repeat_from = options.get("repeat_from", lines.size() - 1)
		npc.dialogue = dialogue
	npc.model_scale = options.get("scale", 1.0)
	npc.can_be_hurt = options.get("hurt", false)
	npc.gold = options.get("gold", 0)
	npc.spawn_on_start = options.get("on_start", true)
	if options.has("recruit"):
		npc.recruit_as = _units[options.recruit]
	return _node(parent, npc, node_name, at, yaw) as NeutralSpawn


func _trigger(parent: Node, node_name: String, at: Vector3, radius := 5.0) -> MapTrigger:
	var trigger := MapTrigger.new()
	trigger.radius = radius
	return _node(parent, trigger, node_name, at) as MapTrigger


func _exit(parent: Node, node_name: String, at: Vector3, target: String, arrival: String, title := "") -> MapExit:
	var exit := MapExit.new()
	exit.target_map = target
	exit.arrival = arrival
	if not title.is_empty():
		exit.set("title", title)
	return _node(parent, exit, node_name, at) as MapExit


func _quest(parent: Node, title: String, description: String, start_active := true) -> Quest:
	var quest := Quest.new()
	quest.title = title
	quest.description = description
	quest.start_active = start_active
	return _node(parent, quest, title.replace("'", "").replace(" ", "")) as Quest


## A step: goal is "talk", "reach", "kill", "flag" or "manual"; `target` the NeutralSpawn, the
## MapTrigger, the unit id (kills) or the flag.
func _step(quest: Quest, objective: String, goal: String, target: Variant = null, options := {}) -> QuestStep:
	var step := QuestStep.new()
	step.objective = objective
	match goal:
		"talk":
			step.goal = QuestStep.Goal.TALK
			step.npc = target
		"reach":
			step.goal = QuestStep.Goal.REACH
			step.trigger = target
		"kill":
			step.goal = QuestStep.Goal.KILL
			step.kill_unit = _units[target] if _units.has(target) else load("res://data/units/%s.tres" % target)
			step.kill_count = options.get("count", 1)
		"flag":
			step.goal = QuestStep.Goal.FLAG
			step.flag = target
		"item":
			step.goal = QuestStep.Goal.ITEM
			step.item = load("res://data/items/%s.tres" % target)
		_:
			step.goal = QuestStep.Goal.MANUAL
	step.message = options.get("message", "")
	step.reward_gold = options.get("gold", 0)
	var flags: Array[StringName] = []
	for flag: String in options.get("flags", []):
		flags.append(StringName(flag))
	step.set_flags = flags
	var recruits: Array[NeutralSpawn] = []
	for npc: NeutralSpawn in options.get("recruit", []):
		recruits.append(npc)
	step.recruit = recruits
	var spawners: Array[CreepSpawner] = []
	for spawner: CreepSpawner in options.get("spawners", []):
		spawners.append(spawner)
	step.activate_spawners = spawners
	return _node(quest, step, "Step%d" % (quest.get_child_count() + 1)) as QuestStep


## A scene: lines "Speaker: text"; `speakers` maps names to nodes (null: a voice from nowhere).
func _scene(parent: Node, node_name: String, lines: Array, speakers := {}, options := {}) -> StoryScene:
	var scene := StoryScene.new()
	scene.lines = PackedStringArray(lines)
	_node(parent, scene, node_name)
	var paths: Dictionary[String, NodePath] = {}
	for speaker: String in speakers:
		paths[speaker] = scene.get_path_to(speakers[speaker]) if speakers[speaker] != null else NodePath()
	scene.speakers = paths
	scene.play_on_start = options.get("on_start", false)
	scene.once = options.get("once", true)
	scene.time_of_day = StringName(options.get("time", ""))
	scene.travel_to = options.get("travel_to", "")
	scene.set_flags = _flags(options.get("flags", []))
	scene.only_if = _flags(options.get("only_if", []))
	scene.unless = _flags(options.get("unless", []))
	return scene


func _gate(parent: Node, node_name: String, flags: Array, options := {}) -> StoryGate:
	var gate := StoryGate.new()
	gate.flags = _flags(flags)
	gate.needed = options.get("needed", 0)
	gate.unless = _flags(options.get("unless", []))
	gate.requires = _flags(options.get("requires", []))
	gate.reversible = options.get("reversible", false)
	gate.set_flags = _flags(options.get("flags", []))
	gate.clear_flags = _flags(options.get("clear", []))
	gate.time_of_day = StringName(options.get("time", ""))
	var show: Array[Node] = []
	show.assign(options.get("show", []))
	gate.show = show
	var hide: Array[Node] = []
	hide.assign(options.get("hide", []))
	gate.hide = hide
	return _node(parent, gate, node_name) as StoryGate


## A job takes the day: arriving on its map uses up the night's rest (`rested`), and the day's
## work waits for the next one, at the inn.
func _spend_the_day() -> void:
	_gate(_story, "TheDaysWork", [], {"reversible": true, "clear": ["rested"]})


func _flags(names: Array) -> Array[StringName]:
	var flags: Array[StringName] = []
	for flag: String in names:
		flags.append(StringName(flag))
	return flags


func _connect(source: Object, signal_name: StringName, target: Object, method: StringName) -> void:
	source.connect(signal_name, Callable(target, method), CONNECT_PERSIST)


## A camp of `count` of one unit, standing in a ring; `respawn` 0: once gone, gone.
func _camp(parent: Node, node_name: String, at: Vector3, unit: String, count: int, options := {}) -> NeutralCamp:
	var camp := NeutralCamp.new()
	var creatures: Array[UnitDefinition] = []
	var spots := PackedVector3Array()
	var sizes := PackedFloat32Array()
	var groups := PackedInt32Array()
	var gold := PackedInt32Array()
	var radius: float = options.get("radius", 1.8 if count > 1 else 0.0)
	for i in count:
		var angle := TAU * i / count
		creatures.append(_units[unit] if _units.has(unit) else load("res://data/units/%s.tres" % unit))
		spots.append(Vector3(cos(angle), 0, sin(angle)) * radius)
		sizes.append(options.get("scale", 1.0))
		groups.append(0)
		gold.append(options.get("gold", 3))
	camp.creatures = creatures
	camp.spots = spots
	camp.sizes = sizes
	camp.groups = groups
	camp.gold = gold
	camp.camp_size = 0
	camp.respawn_time = options.get("respawn", 0.0)
	camp.spawn_on_start = options.get("on_start", true)
	camp.champion_chance = options.get("champion", 0.0)  # a champion pack, now and then
	var modifiers: Array[MonsterModifier] = []
	for modifier: String in options.get("modifiers", []):
		modifiers.append(load("res://data/modifiers/%s.tres" % modifier))
	camp.modifiers = modifiers  # a champion for sure, with these
	return _node(parent, camp, node_name, at) as NeutralCamp


## Enemy waves from `at` along `lane` (CreepWaves sends them once activated).
func _spawner(parent: Node, node_name: String, at: Vector3, lane: Array, melee: String, ranged := "", team := 2) -> CreepSpawner:
	var spawner := CreepSpawner.new()
	spawner.team = team
	spawner.melee = _units[melee] if _units.has(melee) else load("res://data/units/%s.tres" % melee)
	if not ranged.is_empty():
		spawner.ranged = _units[ranged] if _units.has(ranged) else load("res://data/units/%s.tres" % ranged)
	spawner.active = false
	spawner.wave_on_activate = true
	_node(parent, spawner, node_name, at)
	var nodes: Array[Node3D] = []
	for i in lane.size():
		nodes.append(_marker(spawner, "Lane%d" % (i + 1), (lane[i] as Vector3) - at))
	spawner.lane_nodes = nodes
	return spawner


func _waves(parent: Node, interval: float) -> CreepWaves:
	var waves := CreepWaves.new()
	waves.registry = _root.get_node("UnitRegistry")
	waves.first_wave_delay = interval
	waves.wave_interval = interval
	waves.melee_count = PackedInt32Array([3, 3, 4, 4, 5, 5])
	waves.ranged_count = PackedInt32Array([1, 1, 1, 2, 2, 2])
	waves.siege_count = PackedInt32Array([0, 0, 0, 0, 0, 0])
	return _node(parent, waves, "Waves") as CreepWaves


func _box(parent: Node, node_name: String, at: Vector3, size: Vector3, material: Material, yaw := 0.0) -> MapObstacle:
	var box := MapObstacle.new()
	box.shape = MapObstacle.Shape.BOX
	box.size = size
	box.material = material
	return _node(parent, box, node_name, at, yaw) as MapObstacle


## A house: walls under a thatched roof (a placeholder until there are buildings).
func _house(parent: Node, node_name: String, at: Vector3, size: Vector3, yaw := 0.0) -> Node3D:
	var house := _group(parent, node_name)
	house.position = at
	house.rotation.y = yaw
	_box(house, "Walls", Vector3.ZERO, size, _plaster)
	var roof := MapObstacle.new()
	roof.shape = MapObstacle.Shape.CYLINDER
	roof.size = Vector3(maxf(size.x, size.z) * 1.15, 2.2, maxf(size.x, size.z) * 1.15)
	roof.sides = 4
	roof.taper = 0.0
	roof.material = _thatch
	roof.keep_on_ground = false
	roof.blocks_movement = false
	_node(house, roof, "Roof", Vector3(0, size.y, 0), PI * 0.25)
	return house


## The model in a HoN prop's folder (the folder's and the file's names don't always match).
func _prop_scene(kind: String) -> PackedScene:
	var folder := PROP.get_base_dir().get_base_dir() + "/" + kind
	for file in DirAccess.get_files_at(folder):
		if file.ends_with(".glb"):
			return load(folder + "/" + file)
	push_error("no model in " + folder)
	return null


## A HoN prop (assets/environment/hon/props) standing on the map.
func _prop(parent: Node, kind: String, at: Vector3, yaw := 0.0, scale := 1.0, blocks := true) -> Node3D:
	var prop: Node3D = _prop_scene(kind).instantiate()
	prop.set_script(MAP_PROP)
	prop.set("blocks_movement", blocks)
	prop.scale = Vector3.ONE * scale
	return _node(parent, prop, kind.capitalize().replace(" ", "") + str(parent.get_child_count()), at, yaw) as Node3D


# --- Big maps from pieces (DIRECTION.md 5) ------------------------------------------

## Lays out a big map: `stops` along a winding road (AreaPlan), `sides` off it; returns the plan
## and the terrain spec's roads and clearings to pass to _begin().
## `heading`: where the main road runs (north, south, east, west); `branches`: [from stop, [its stops],
## length in cells] each, side roads to places of their own.
func _plan(size: Vector2i, seed: int, stops: Array[String], sides: Array[String], path_tile: String,
		clearing_tile: String, heading := "north", branches := []) -> Array:
	var plan := AreaPlan.new(size, seed)
	plan.lay_road(stops, heading)
	for branch: Array in branches:
		var branch_stops: Array[String] = []
		branch_stops.assign(branch[1])
		if not plan.add_branch(branch[0], branch_stops, branch[2]):
			push_warning("no room for the branch to %s" % [branch[1]])
	for side in sides:
		plan.add_side(side)
	var areas := []
	for place: String in plan.places:
		var at: Vector3 = plan.places[place]
		areas.append({"center": Vector2(at.x, at.z), "radius": 9.0, "tile": clearing_tile})
	var paths := [{"points": plan.road_points(), "width": 2.6, "tile": path_tile}]
	for points: Array in plan.branch_points():
		paths.append({"points": points, "width": 2.0, "tile": path_tile})
	var spec_parts := {"paths": paths, "areas": areas}
	return [plan, spec_parts]


## Fills the plan's free cells near the road with `biome`'s pieces, its monsters in most of them, and
## puts a shrine and a guarded cache in the side places named "Shrine" and "Cache" (if planned).
func _fill(plan: RefCounted, biome: String) -> void:
	var rules: Dictionary = BIOMES[biome]
	var rng: RandomNumberGenerator = plan.rng
	var pieces := _group(_story, "Pieces")
	var monsters := _group(_story, "Monsters")
	var kinds: Array = rules.pieces.keys()
	var weights := PackedFloat32Array()
	for kind: String in kinds:
		weights.append(rules.pieces[kind])
	var i := 0
	for cell: Vector2i in plan.filler():
		var at: Vector3 = plan.world(cell) + Vector3(rng.randf_range(-3, 3), 0, rng.randf_range(-3, 3))
		var kind: String = kinds[rng.rand_weighted(weights)]
		_piece(kind, pieces, at, rng, rules.trees)
		var ahead: float = plan.progress(cell)
		if kind != "clearing" and rng.randf() < rules.get("packs", 0.55) + ahead * 0.3:  # "packs": how often a piece has some
			var unit: String = rules.monsters[rng.randi_range(0, rules.monsters.size() - 1)]
			_camp(monsters, "Pack%d" % i, at, unit, 2 + int(ahead * 3.0 + rng.randf() * 1.5),
					{"champion": 0.08 + ahead * 0.35, "gold": 2})
		i += 1
	# Away from the road: scenery only, so the wild isn't bare (the biome's own look, no monsters)
	var scenery: Array = rules.get("scenery", ["woods", "woods", "rocks", "clearing"])
	for cell: Vector2i in plan.wild():
		if rng.randf() < 0.75:
			var at: Vector3 = plan.world(cell) + Vector3(rng.randf_range(-4, 4), 0, rng.randf_range(-4, 4))
			_piece(scenery[rng.randi_range(0, scenery.size() - 1)], pieces, at, rng, rules.trees)
	_roadside(plan)
	if plan.places.has("Shrine"):
		var shrine := Shrine.new()
		shrine.blessing = rng.randi_range(0, Shrine.Blessing.size() - 1) as Shrine.Blessing
		_node(_story, shrine, "Shrine", plan.places["Shrine"])
	if plan.places.has("Cache"):
		var at: Vector3 = plan.places["Cache"]
		var chest := Chest.new()
		chest.random_items = 2
		chest.better_odds = true
		chest.item_level = (_root.get_node("UnitRegistry") as UnitRegistry).monster_level
		chest.gold = 15
		_node(_story, chest, "Cache", at, rng.randf() * TAU)
		_piece("ruin", pieces, at, rng, rules.trees)
		var guard: String = rules.monsters[0]
		_camp(monsters, "CacheGuard", at + Vector3(0, 0, 4), guard, 3, {"champion": 1.0, "gold": 4})


## Small things along the road, both sides every few metres: ferns, flowers, bushes, stumps, rocks, so a road isn't a
## bare strip (clear of its middle: nothing blocks it).
func _roadside(plan: RefCounted) -> void:
	var rng: RandomNumberGenerator = plan.rng
	var side := _group(_story, "Roadside")
	var points: Array = plan.road_points()
	for i in points.size() - 1:
		var from: Vector2 = points[i]
		var to: Vector2 = points[i + 1]
		var length := from.distance_to(to)
		var along := (to - from).normalized()
		var across := Vector2(-along.y, along.x)
		var t := rng.randf_range(2.0, 5.0)
		while t < length:
			var spot := from + along * t + across * rng.randf_range(3.2, 6.5) * (1.0 if rng.randf() < 0.5 else -1.0)
			var at := Vector3(spot.x, 0, spot.y)
			var model: String = ["fern", "flowers_1", "bush_1", "bush_2", "stump_1", "log_1", "mushroom_1", "grass_2"][rng.randi_range(0, 7)]
			_nature(side, model, at, rng.randf() * TAU, rng.randf_range(0.8, 1.3), false)
			if rng.randf() < 0.18:
				_nature(side, "rock_%d" % rng.randi_range(1, 4), at + Vector3(1.2, 0, 0.8), rng.randf() * TAU, rng.randf_range(0.5, 0.9), true)
			t += rng.randf_range(4.0, 9.0)


## One piece of a map: a few props from the kits around `at` (kept off its middle, where its monsters
## stand). Kinds: woods, rocks, graves, ruin, house, campsite, field, clearing.
func _piece(kind: String, parent: Node3D, at: Vector3, rng: RandomNumberGenerator, trees: Array = ["fir_1"]) -> void:
	var group := _group(parent, kind.capitalize() + str(parent.get_child_count()))
	group.position = at
	var around := func(low: float, high: float) -> Vector3:
		var angle := rng.randf() * TAU
		return Vector3(cos(angle), 0, sin(angle)) * rng.randf_range(low, high)
	match kind:
		"woods":
			for n in rng.randi_range(7, 11):
				_nature(group, trees[rng.randi_range(0, trees.size() - 1)], around.call(4.5, 10.5), rng.randf() * TAU,
						rng.randf_range(0.55, 0.85), true)  # the pack's trees are big next to the characters
			for n in 3:
				_nature(group, ["bush_1", "log_1", "stump_1"][n], around.call(3.5, 9.0), rng.randf() * TAU, 1.0, false)
		"rocks":
			for n in rng.randi_range(3, 5):
				_nature(group, "rock_%d" % rng.randi_range(1, 4), around.call(4.0, 9.0), rng.randf() * TAU, rng.randf_range(0.6, 1.1), true)
			_nature(group, "stump_2", around.call(3.0, 6.0), rng.randf() * TAU, 1.0, false)
		"graves":
			var yaw := rng.randf() * TAU
			for row in 2:
				for n in rng.randi_range(3, 4):
					var offset := Vector3(-4.5 + n * 3.0, 0, -5.0 + row * 10.0).rotated(Vector3.UP, yaw)
					_prop(group, "grave", offset, yaw, 1.0)
			_prop(group, "skull_pile", around.call(4.0, 7.0), rng.randf() * TAU, 1.0, false)
			_prop(group, "brokencolumn", around.call(6.0, 9.0), rng.randf() * TAU, 1.0)
		"ruin":
			var yaw := rng.randf() * TAU
			var wall := "village/Wall_UnevenBrick_Straight"
			for n in 3:
				_kit(group, wall, Vector3(-6.0 + n * 2.0, 0, -6.0).rotated(Vector3.UP, yaw), yaw, 1.0, true)
			for n in 2:
				_kit(group, wall, Vector3(-7.0, 0, -5.0 + n * 2.0).rotated(Vector3.UP, yaw), yaw + PI * 0.5, 1.0, true)
			_prop(group, "brokencolumn", Vector3(5, 0, 4).rotated(Vector3.UP, yaw), rng.randf() * TAU, 1.0)
			for n in 2:
				_kit(group, "village/Prop_Crate", around.call(4.0, 8.0), rng.randf() * TAU, 1.0, true)
		"house":
			var yaw := rng.randi_range(0, 3) * PI * 0.5 + rng.randf_range(-0.2, 0.2)
			_kit_house(group, "House", Vector3(0, 0, -6.5).rotated(Vector3.UP, yaw), yaw, 3, 4, rng.randf() < 0.5)
			_kit(group, "village/Prop_Crate", Vector3(4.0, 0, -2.0).rotated(Vector3.UP, yaw), yaw, 1.0, true)
			for n in 3:
				_kit(group, "village/Prop_WoodenFence_Single", Vector3(-3.0 + n * 2.1, 0, 4.5).rotated(Vector3.UP, yaw), yaw, 1.0, true)
		"campsite":
			_campfire(group, Vector3(0, 0, -4))
			_nature(group, "log_2", Vector3(2.2, 0, -4), 0.0, 0.8, false)
			_kit(group, "village/Prop_Crate", around.call(5.0, 8.0), rng.randf() * TAU, 1.0, true)
			_kit(group, "dungeon/Barrel", around.call(5.0, 8.0), 0.0, 1.0, true)
		"field":
			var yaw := rng.randf() * TAU
			for n in 6:
				_kit(group, "village/Prop_WoodenFence_Single", Vector3(-7.0 + n * 2.1, 0, -7.0).rotated(Vector3.UP, yaw), yaw, 1.0, true)
			_kit(group, "village/Prop_Wagon", Vector3(6.0, 0, 3.0).rotated(Vector3.UP, yaw), yaw + 0.4, 1.0, true)
			for n in 4:
				_nature(group, ["grass_1", "grass_2", "flowers_1", "grass_1"][n], around.call(3.0, 8.0), rng.randf() * TAU, 1.0, false)
		"relic":  # one of the prologue's hand-built groups (scenes/presets/prologue), as it stands
			_preset(group, ["bonfire", "skeleton", "lantern", "stump"][rng.randi_range(0, 3)], Vector3.ZERO, rng.randf() * TAU)
			_nature(group, "fern", around.call(3.0, 6.0), rng.randf() * TAU, 1.0, false)
		"clearing":
			for n in 5:
				_nature(group, ["fern", "flowers_1", "bush_2", "mushroom_1", "flowers_2"][n], around.call(3.0, 9.0), rng.randf() * TAU,
						1.0, false)


## A model from the nature pack (assets/environment/FULL_VERSION_ALL_MODELS: trees, rocks, bushes) on the
## map. Trees block by their trunk and fade when they hide a unit, as in the prologue.
func _nature(parent: Node3D, model: String, at: Vector3, yaw := 0.0, scale := 1.0, blocks := false) -> Node3D:
	var prop: Node3D = (load("res://assets/environment/FULL_VERSION_ALL_MODELS/GLB/%s.glb" % model) as PackedScene).instantiate()
	prop.set_script(MAP_PROP)
	prop.set("blocks_movement", blocks)
	var tree := not (model.begins_with("rock") or model.begins_with("bush") or model.begins_with("stump") or model.begins_with("log")
			or model in ["fern", "flowers_1", "flowers_2", "mushroom_1", "mushroom_2", "grass_1", "grass_2"])
	if tree:
		prop.set("footprint", MAP_PROP.Footprint.CYLINDER)
		prop.set("footprint_scale", 0.35)
		prop.set("see_through_scale", 2.0)
	prop.scale = Vector3.ONE * scale
	return _node(parent, prop, model + "_" + str(parent.get_child_count()), at, yaw) as Node3D


## A house from the village kit: `wide` x `deep` wall pieces (2 m each), a door in the front, windows
## on the sides, corner posts, the round-tile roof that fits and its gables; plaster or brick. One
## MapProp: it blocks movement and sight as a whole.
func _kit_house(parent: Node3D, node_name: String, at: Vector3, yaw: float, wide: int, deep: int, brick := false) -> Node3D:
	var house := Node3D.new()
	house.set_script(MAP_PROP)
	house.set("blocks_movement", true)
	_node(parent, house, node_name + str(parent.get_child_count()), at, yaw)
	var style := "UnevenBrick" if brick else "Plaster"
	var width := wide * 2.0
	var depth := deep * 2.0
	var piece := func(file: String, where: Vector3, turn: float) -> void:
		var model: Node3D = (load("res://assets/environment/village/%s.glb" % file) as PackedScene).instantiate()
		house.add_child(model)
		model.position = where
		model.rotation.y = turn
		model.owner = _root
	for n in wide:
		var x := -width * 0.5 + 1.0 + n * 2.0
		var front := "Wall_%s_Door_Round" % style if n == wide / 2 else "Wall_%s_Straight" % style
		piece.call(front, Vector3(x, 0, depth * 0.5), PI)
		piece.call("Wall_%s_Straight" % style, Vector3(x, 0, -depth * 0.5), 0.0)
	for n in deep:
		var z := -depth * 0.5 + 1.0 + n * 2.0
		var side := "Wall_%s_Window_Wide_Round" % style if n % 2 == 1 else "Wall_%s_Straight" % style
		piece.call(side, Vector3(width * 0.5, 0, z), -PI * 0.5)
		piece.call(side, Vector3(-width * 0.5, 0, z), PI * 0.5)
	for corner in [Vector3(1, 0, 1), Vector3(-1, 0, 1), Vector3(1, 0, -1), Vector3(-1, 0, -1)]:
		piece.call("Corner_Exterior_Wood", Vector3(corner.x * width * 0.5, 0, corner.z * depth * 0.5), 0.0)
	piece.call("Roof_RoundTiles_%dx%d" % [int(width), int(depth)], Vector3(0, 3.12, 0), 0.0)
	piece.call("Roof_Front_Brick%d" % int(width), Vector3(0, 3.12, depth * 0.5), 0.0)
	piece.call("Roof_Front_Brick%d" % int(width), Vector3(0, 3.12, -depth * 0.5), PI)
	return house


# --- Terrain ---------------------------------------------------------------------

func _tile(tile_name: String) -> int:
	for i in _tileset.tiles.size():
		if _tileset.tiles[i].name == tile_name:
			return i
	push_error("no tile " + tile_name)
	return 0


## A terrain: hills that rise into a rim at the edges (the map's border), ground, patches,
## roads (flattened), clearings and a river. Keys: size, seed, ground, patch, cliff, hills,
## rim, paths [{points, width, tile}], areas [{center, radius, tile}], river {points, width}.
func _save_terrain(file: String, spec: Dictionary) -> TerrainData:
	var size: Vector2i = spec.size
	var data := TerrainData.create(size, 1.0, _tile(spec.ground))
	var noise := FastNoiseLite.new()
	noise.seed = spec.get("seed", 1)
	noise.frequency = 1.0 / 22.0
	noise.fractal_octaves = 3
	var patches := FastNoiseLite.new()
	patches.seed = spec.get("seed", 1) + 7
	patches.frequency = 1.0 / 9.0
	var half := Vector2(size) * 0.5
	var ground := _tile(spec.ground)
	var patch := _tile(spec.get("patch", spec.ground))
	var cliff := _tile(spec.get("cliff", "g1_cliff"))
	var hills: float = spec.get("hills", 1.6)
	var rim: float = spec.get("rim", 9.0)
	for z in size.y + 1:
		for x in size.x + 1:
			var world := Vector2(x, z) - half
			var edge := maxf(absf(world.x) / half.x, absf(world.y) / half.y)
			var lift := smoothstep(0.8, 0.98, edge) * rim
			var height := (noise.get_noise_2dv(world) * 0.5 + 0.5) * hills + lift
			var tile := patch if patches.get_noise_2dv(world) > 0.3 else ground
			for path: Dictionary in spec.get("paths", []):
				var distance := _distance_to_line(world, path.points)
				if distance < path.width:
					tile = _tile(path.tile)
					height = lerpf(height, minf(height, hills * 0.4), smoothstep(path.width, path.width * 0.4, distance))
			for area: Dictionary in spec.get("areas", []):
				var distance: float = world.distance_to(area.center)
				if distance < area.radius:
					tile = _tile(area.tile)
					height = lerpf(height, minf(height, hills * 0.4), smoothstep(area.radius, area.radius * 0.5, distance))
			if spec.has("river"):
				var river: Dictionary = spec.river
				var distance := _distance_to_line(world, river.points)
				if distance < river.width:
					tile = _tile("river1")
					height -= 0.7 * smoothstep(river.width, river.width * 0.3, distance)
			if lift > 3.0:
				tile = cliff
			var i := data.index(x, z)
			data.heights[i] = height
			data.tiles[i] = tile
	_relax_slopes(data, cliff)
	var path := "res://data/terrain/story/%s_terrain.res" % file
	if not FileAccess.file_exists(path) or _rewrite:
		print("terrain %s: %s" % [file, error_string(ResourceSaver.save(data, path))])
	else:
		data = load(path)
		var before := data.heights.duplicate()
		_relax_slopes(data, cliff)
		if data.heights != before:  # the baked terrains get the same pass (their cliffs and rims are left alone)
			print("terrain %s eased: %s" % [file, error_string(ResourceSaver.save(data, path))])
	data.take_over_path(path)
	return data


## The walkable ground's slopes made walkable (the navigation mesh takes up to 55 degrees): between two neighbouring
## vertices a step steeper than WALKABLE_SLOPE, but not a deliberate cliff (nothing above STEEPEST_RELAXED, and never
## next to a cliff tile), is eased to WALKABLE_SLOPE, a little of each side at a time. Real cliffs (the rim, any
## rise above STEEPEST_RELAXED) stay as they are: those are meant to be walls.
const WALKABLE_SLOPE := 50.0
const STEEPEST_RELAXED := 72.0

func _relax_slopes(data: TerrainData, cliff: int) -> void:
	var limit := tan(deg_to_rad(WALKABLE_SLOPE)) * data.cell_size
	var wall := tan(deg_to_rad(STEEPEST_RELAXED)) * data.cell_size
	var changed := 0
	for pass_number in 24:
		var moved := false
		for z in data.size.y + 1:
			for x in data.size.x + 1:
				for step: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
					var nx := x + step.x
					var nz := z + step.y
					if nx > data.size.x or nz > data.size.y:
						continue
					var a := data.index(x, z)
					var b := data.index(nx, nz)
					if data.tiles[a] == cliff or data.tiles[b] == cliff:
						continue
					var rise: float = data.heights[b] - data.heights[a]
					if absf(rise) <= limit or absf(rise) >= wall:
						continue
					var ease_by := (absf(rise) - limit) * 0.5
					data.heights[a] += ease_by * signf(rise)
					data.heights[b] -= ease_by * signf(rise)
					moved = true
					changed += 1
		if not moved:
			break
	if changed > 0:
		print("slopes eased: %d steps" % changed)


static func _distance_to_line(point: Vector2, points: Array) -> float:
	var best := INF
	for i in points.size() - 1:
		best = minf(best, point.distance_to(Geometry2D.get_closest_point_to_segment(point, points[i], points[i + 1])))
	return best


# --- 2a. The Night Vigil ------------------------------------------------------------

func _make_vigil() -> void:
	if _exists(VIGIL):
		return
	_begin("The Night Vigil", "NightVigil", {"size": Vector2i(64, 64), "seed": 11, "ground": "g1_ground", "patch": "b1_roots",
			"paths": [{"points": [Vector2(0, 32), Vector2(0, 2)], "width": 2.0, "tile": "g1_path"}],
			"areas": [{"center": Vector2(0, -2), "radius": 9.0, "tile": "g1_trail"}]}, "night", Vector3(0, 0, 20))
	var place := _group(_story, "Chapel")
	_house(place, "ChapelOfStLammas", Vector3(0, 0, -8), Vector3(7, 5, 10))
	var graves := _group(_story, "Graves")
	for side: Vector3 in [Vector3(-16, 0, -6), Vector3(16, 0, -6), Vector3(0, 0, -19)]:
		for i in 6:
			_prop(graves, "grave", side + Vector3((i % 3) * 2.2 - 2.2, 0, (i / 3) * 2.6), randf() * 0.4, 1.0)
	var aldith := _npc(_story, "SerAldith", Vector3(0, 0, -1.5), 0.0, "aldith", "Ser Aldith", [
		"Another night, then. They come from the graves on three sides.",
		"My order left the valley. I didn't. Thirty nights I've held this door.",
		"Stand with me until dawn, mage, and the chapel's silver is yours.",
	], {"recruit": "aldith"})
	var lanes := _group(_story, "Waves")
	var west := _spawner(lanes, "WestGraves", Vector3(-18, 0, -6), [Vector3(-8, 0, -2), Vector3(0, 0, 1)], "skeleton_minion")
	var east := _spawner(lanes, "EastGraves", Vector3(18, 0, -6), [Vector3(8, 0, -2), Vector3(0, 0, 1)], "skeleton_minion")
	var north := _spawner(lanes, "NorthGraves", Vector3(0, 0, -21), [Vector3(-6, 0, -15), Vector3(0, 0, 1)], "skeleton_minion", "skeleton_mage")
	var waves := _waves(lanes, 26.0)
	waves.melee_count = PackedInt32Array([1, 2, 2, 2, 3, 3])  # three graveyards at once: small waves
	waves.ranged_count = PackedInt32Array([0, 0, 1, 1, 1, 1])
	var exit := _exit(_story, "ToNetherby", Vector3(0, 0, 23), VILLAGE, "Story/Arrivals/FromVigil", "Back to Netherby")
	var quest := _quest(_story, "The Night Vigil", "Hold the chapel of St. Lammas with Ser Aldith until dawn.")
	_step(quest, "Talk to Ser Aldith at the chapel door", "talk", aldith, {"spawners": [west, east, north], "recruit": [aldith]})
	var hold := _step(quest, "Hold the chapel with Ser Aldith until dawn", "kill", "skeleton_minion", {"count": 14})
	var dawn := _scene(_story, "Dawn", [
		"Ser Aldith: Dawn. Look at it. I'd stopped believing in it.",
		"Maren: They're going back into the ground.",
		"Ser Aldith: Until tonight. They always come back.",
		"Ser Aldith: My order rode out of this valley and never looked back. You didn't run. My sword is yours, if you'll have an old soldier.",
	], {}, {"time": "dawn", "flags": ["job_vigil_done"]})
	_connect(hold, &"completed", dawn, &"play")
	for spawner in [west, east, north]:
		_connect(dawn, &"finished", spawner, &"deactivate")
	var paid := _step(quest, "Hear Ser Aldith out", "manual", null, {"gold": 30})
	_connect(dawn, &"finished", paid, &"complete")
	_spend_the_day()
	_step(quest, "Return to Netherby", "manual")
	_gate(_story, "WayBack", ["job_vigil_done"], {"show": [exit]})
	_finish(VIGIL)


# --- 2b. Debts of the Living --------------------------------------------------------

func _make_debts() -> void:
	if _exists(_variant_path(DEBTS)):
		return
	var size := Vector2i(176, 176)
	var stops: Array[String] = ["Start", "Lanes", "Nell", "OldGate"]
	var laid := _plan(size, 23 + _variant * 101, stops, ["Shrine", "Cache"], "g1_path", "g1_trail", "west", [["Lanes", ["CoynesHouse"], 3]])
	var plan: RefCounted = laid[0]
	var spec := {"size": size, "seed": 23 + _variant * 101, "ground": "g1_ground", "patch": "g1_trail"}
	spec.merge(laid[1])
	var start: Vector3 = plan.places["Start"]
	_begin("Debts of the Living", "DebtsOfTheLiving", spec, "night", start)
	_fill(plan, "lanes")
	var lanes: Vector3 = plan.places["Lanes"]
	var nell_at: Vector3 = plan.places["Nell"]
	var gate: Vector3 = plan.places["OldGate"]
	var houses := _group(_story, "Lanes")
	for i in 3:
		_kit_house(houses, "LaneHouse", lanes + Vector3(-12 + i * 12, 0, -10), 0.0, 3, 4, i == 1)
	_prop(houses, "cauldron", lanes + Vector3(0, 0, 4), 0.0, 1.0)
	_kit_house(houses, "TheMill", nell_at + Vector3(8, 0, -6), 0.4, 4, 4, true)
	var nell := _npc(_story, "Nell", nell_at, 0.6, "nell", "Nell", ["You're not Coyne's. Good. Keep your voice down."], {"recruit": "nell"})
	var men := _group(_story, "CoynesMen")
	if plan.places.has("CoynesHouse"):  # the moneylender's: bigger than the rest, guarded
		var house: Vector3 = plan.places["CoynesHouse"]
		_kit_house(houses, "CoynesHouse", house + Vector3(0, 0, -6), 0.0, 4, 4, true)
		_npc(_story, "CoynesBooks", house + Vector3(2, 0, 1), 0.0, "clue", "Edith Coyne's other book", [
			"Not debts: deliveries. 'Twelve, to the Gleaners' Lodge, paid in full.' 'Nine, to the Lodge.' 'Fifteen.'",
			"In the margin, in her hand: 'They don't come back. Don't ask. The silver is good.'",
		], {"scale": 0.5})
		var strongbox := Chest.new()
		strongbox.random_items = 1
		strongbox.better_odds = true
		strongbox.gold = 30
		_node(houses, strongbox, "Strongbox", house + Vector3(-3, 0, 1), 0.0)
		_camp(men, "AtCoynes", house + Vector3(0, 0, 4), "thug", 3, {"champion": 0.6})
	_camp(men, "AtTheWell", lanes + Vector3(4, 0, 6), "thug", 2)
	_camp(men, "ByTheMill", nell_at + Vector3(-6, 0, -6), "thug", 3)
	_camp(men, "AtTheGate", gate + Vector3(4, 0, 4), "thug", 3, {"champion": 0.5})
	var gate_trigger := _trigger(_story, "OldGate", gate, 4.0)
	var exit := _exit(_story, "ToNetherby", gate, VILLAGE, "Story/Arrivals/FromDebts", "Back to Netherby")
	var quest := _quest(_story, "Debts of the Living", "Find Nell in the lanes by the old mill and get her out past the moneylender's men.")
	var found := _step(quest, "Find Nell in the lanes by the old mill", "talk", nell, {"recruit": [nell]})
	var story := _scene(_story, "NellFound", [
		"Nell: I took Edith Coyne's book. Her ledger.",
		"Nell: Half the names in it went to 'work in the valley' and never came back. Every one of them signed something first.",
		"Maren: And now her men want it back.",
		"Nell: Her men want me in the river. Get me to the old gate and I'm yours. I mean it. I owe you.",
	], {"Nell": nell})
	_connect(found, &"completed", story, &"play")
	_step(quest, "Get Nell to the old gate", "reach", gate_trigger, {"flags": ["job_debts_done"], "gold": 25})
	_spend_the_day()
	_step(quest, "Return to Netherby", "manual")
	_gate(_story, "WayBack", ["job_debts_done"], {"show": [exit]})
	_finish(_variant_path(DEBTS))


# --- 2c. What Hunts the Hunters ---------------------------------------------------------

func _make_hunt() -> void:
	if _exists(_variant_path(HUNT)):
		return
	var size := Vector2i(192, 192)
	var stops: Array[String] = ["Start", "TamsinsCamp", "Snares", "Den"]
	var laid := _plan(size, 37 + _variant * 101, stops, ["Shrine", "Cache"], "g1_trail", "b1_roots", "north", [["TamsinsCamp", ["OldBlind"], 3]])
	var plan: RefCounted = laid[0]
	var spec := {"size": size, "seed": 37 + _variant * 101, "ground": "g1_ground", "patch": "g2_trees", "cliff": "g1_cliff", "hills": 2.4}
	spec.merge(laid[1])
	var start: Vector3 = plan.places["Start"]
	_begin("What Hunts the Hunters", "WhatHuntsTheHunters", spec, "dusk", start)
	_fill(plan, "wood")
	var camp_at: Vector3 = plan.places["TamsinsCamp"]
	var snares: Vector3 = plan.places["Snares"]
	var den: Vector3 = plan.places["Den"]
	var woods := _group(_story, "Woods")
	_campfire(woods, camp_at + Vector3(2.5, 0, 1.5))
	var tamsin := _npc(_story, "Tamsin", camp_at, PI, "tamsin", "Tamsin Holt", ["Quiet. They can hear us long before we see them."],
			{"recruit": "tamsin"})
	_prop(woods, "skull_pile", den + Vector3(3, 0, -3), 0.0, 1.2)
	_prop(woods, "giant_ribcage", den + Vector3(-5, 0, -4), 0.6, 1.0)
	var packs := _group(_story, "Packs")
	_camp(packs, "AtTheSnares", snares + Vector3(0, 0, -6), "ghoul", 4, {"champion": 0.6})
	_camp(packs, "Den", den, "ghoul_mother", 1, {"scale": 1.5})
	var snare := _npc(_story, "RowansSnares", snares, 0.0, "clue", "Snares, sprung", [
		"Hunter's snares, sprung and empty. Blood on the wire, days old.",
		"A knife in the leaves: ROWAN burned into the handle.",
	], {"scale": 0.5})
	if plan.places.has("OldBlind"):  # a branch off the camp: the hunters' old blind
		var blind: Vector3 = plan.places["OldBlind"]
		var hide := _group(_story, "OldBlind")
		hide.position = blind
		for n in 4:
			_kit(hide, "village/Prop_WoodenFence_Single", Vector3(-3.0 + n * 2.0, 0, -2.5), 0.0, 1.0, true)
		_nature(hide, "log_1", Vector3(2.5, 0, 1.5), 0.4, 1.0, false)
		var stash := Chest.new()
		stash.random_items = 1
		stash.item_level = 3
		stash.gold = 12
		_node(hide, stash, "HuntersStash", Vector3(-1.5, 0, 1.0), 0.2)
		_npc(_story, "RowansNote", blind + Vector3(1.5, 0, -1.0), 0.0, "clue", "A note, nailed to the post", [
			"'Den's up the wood, past the old graves. Mother's bigger than any I've seen. Going alone tomorrow. Tell Tam I said not to follow. R.'",
		], {"scale": 0.5})
		_camp(packs, "AtTheBlind", blind + Vector3(0, 0, -6), "ghoul", 3, {"champion": 0.3})
	var exit := _exit(_story, "ToNetherby", start + Vector3(4, 0, 6), VILLAGE, "Story/Arrivals/FromHunt", "Back to Netherby")
	var quest := _quest(_story, "What Hunts the Hunters", "Track the ghoul pack to its den with Tamsin Holt.")
	var met := _step(quest, "Find Tamsin at her camp in the wood", "talk", tamsin, {"recruit": [tamsin]})
	var briefing := _scene(_story, "TamsinMeets", [
		"Tamsin Holt: You're the mage Hob sent. Good. Stay behind me.",
		"Tamsin Holt: Rowan went to check the snares three days ago. Rowan doesn't miss three days.",
		"Tamsin Holt: The packs run when they're hurt and come back with friends. Their mother sits in a den up the wood. Kill her and the rest scatter.",
	], {"Tamsin Holt": tamsin, "Tamsin": tamsin})
	_connect(met, &"completed", briefing, &"play")
	var found := _step(quest, "Find Rowan's snares", "talk", snare)
	var rowan := _scene(_story, "RowansKnife", [
		"Tamsin: His knife. He'd never leave his knife.",
		"Tamsin: ...Up the wood, then. To the den. She took Rowan; she's mine.",
	], {"Tamsin": tamsin})
	_connect(found, &"completed", rowan, &"play")
	var mother := _step(quest, "Kill the ghoul mother in her den", "kill", "ghoul_mother", {"flags": ["job_hunt_done"], "gold": 30})
	_spend_the_day()
	var pedlar := _npc(_story, "Pedlar", start + Vector3(-6, 0, -3), 0.4, "pedlar", "A pedlar", ["Charms against the dark, love. Cheap."])
	var trader := Vendor.new()
	trader.title = "A pedlar"
	trader.purse = 45
	trader.markup = 1.2
	var wares: Array[ItemDefinition] = [load("res://data/items/ring_of_regeneration.tres"), load("res://data/items/periapt_of_vitality.tres")]
	trader.stock = wares
	_node(_story, trader, "PedlarsWares")
	trader.host = pedlar
	var cleared := _scene(_story, "DenCleared", [
		"Tamsin: That's for Rowan.",
		"Tamsin: Every hunter in this valley owes you a drink, mage. I'll start paying it.",
	])
	_connect(mother, &"completed", cleared, &"play")
	_step(quest, "Return to Netherby", "manual")
	_gate(_story, "WayBack", ["job_hunt_done"], {"show": [exit]})
	_finish(_variant_path(HUNT))


# --- 3. Briar's Hollow --------------------------------------------------------------

func _make_hollow() -> void:
	if _exists(_variant_path(HOLLOW)):
		return
	var size := Vector2i(176, 176)
	var stops: Array[String] = ["Start", "Square", "WrensHouse", "NorthRoad"]
	var laid := _plan(size, 41 + _variant * 101, stops, ["Shrine", "Cache"], "b1_path", "b1_base", "east", [["Square", ["Chapel"], 3]])
	var plan: RefCounted = laid[0]
	var spec := {"size": size, "seed": 41 + _variant * 101, "ground": "b1_ground", "patch": "b1_roots", "cliff": "b1_cliff"}
	spec.merge(laid[1])
	var start: Vector3 = plan.places["Start"]
	_begin("Briar's Hollow", "BriarsHollow", spec, "dusk", start)
	_fill(plan, "hollow")
	var square: Vector3 = plan.places["Square"]
	var wrens: Vector3 = plan.places["WrensHouse"]
	var north: Vector3 = plan.places["NorthRoad"]
	var houses := _group(_story, "Houses")
	for i in 4:
		var angle := TAU * i / 4.0 + 0.4
		_kit_house(houses, "SquareHouse", square + Vector3(cos(angle), 0, sin(angle)) * 13.0, -angle + PI * 0.5, 3, 4, i % 2 == 0)
	_kit_house(houses, "WrensHouse", wrens + Vector3(0, 0, -6), 0.0, 2, 3)
	_prop(houses, "totem", square, 0.0, 1.0)
	_prop(houses, "skel_sac", square + Vector3(3, 0, 4), 1.2, 1.0)
	var clues := _group(_story, "Clues")
	_npc(clues, "Notice", square + Vector3(-3, 0, 4), 0.0, "clue", "A notice, weathered", [
		"'By order of Father Corwin: the Hollow will keep vigil for the hungry.'",
		"'Bring your dead to the chapel. Do not bury them.'",
	], {"scale": 0.5})
	var wren := _npc(clues, "WrensHouse", wrens + Vector3(0, 0, -1), 0.6, "clue", "Wren's house", [
		"A hunting bow hangs on the wall. The string has never been drawn; the wax is still on it.",
		"The bed is made. The dust on the blanket is unbroken.",
		"No boots by the door. No arrows. Nobody has ever lived here.",
	], {"scale": 0.5})
	_npc(clues, "Slate", square + Vector3(-9, 0, 9), 0.0, "clue", "A child's slate", [
		"'Father Corwin says the Mercy will bring Mama home. Father Corwin says we must be patient.'",
	], {"scale": 0.5})
	var jory := _npc(_story, "Jory", north, 0.0, "jory", "Jory Wainwright", [
		"Don't. Don't draw on me. I'm not one of them... not all the way.",
		"I drove your carriage. I sawed the axle. Forty silver, for my mother's debts. They said nobody would be hurt.",
		"I signed their paper. When the fever took me I came back like this, and I remember everything.",
		"I can't tell you where to go. The oath won't let me. But I can tell you not to sign anything...",
		"...You already did. Didn't you.",
	])
	var husks := _group(_story, "Husks")
	if plan.places.has("Chapel"):  # where Corwin told them to bring their dead
		var chapel: Vector3 = plan.places["Chapel"]
		_kit_house(houses, "TheHollowsChapel", chapel + Vector3(0, 0, -6), 0.0, 3, 6, true)
		for n in 6:
			_prop(houses, "grave", chapel + Vector3(-6.0 + (n % 3) * 3.0, 0, 3.0 + (n / 3) * 3.0), 0.0, 1.0)
		_npc(clues, "ChapelBook", chapel + Vector3(0, 0, 1), 0.0, "clue", "The chapel's book of the dead", [
			"Names, dates, the cause in a neat hand: hunger, hunger, fever, hunger.",
			"The last forty pages say the same thing, in a different hand: 'Kept for the Mercy.'",
			"None of them was buried.",
		], {"scale": 0.5})
		_camp(husks, "ChapelZealots", chapel + Vector3(4, 0, 4), "zealot", 3, {"champion": 0.5})
	_camp(husks, "SquareHusks", square + Vector3(5, 0, 0), "skeleton_minion", 4, {"champion": 0.4})
	_camp(husks, "WrensDoor", wrens + Vector3(4, 0, 2), "zealot", 2, {"champion": 0.25})
	_camp(husks, "NorthEdge", north + Vector3(-6, 0, 6), "ghoul", 3)
	var center := _trigger(_story, "TheSquare", square, 7.0)
	var exit := _exit(_story, "ToTheLodge", north + Vector3(0, 0, -6), LODGE, "", "The road to the lodge")
	var quest := _quest(_story, "Briar's Hollow", "Corwin Hale's daughter Wren lived in Briar's Hollow. Find her, or what happened to her.")
	_step(quest, "Look for Wren in Briar's Hollow", "reach", center)
	_step(quest, "Search Wren's house", "talk", wren)
	var met := _step(quest, "Speak to the figure on the north road", "talk", jory, {"flags": ["hollow_searched"]})
	var doubt := _scene(_story, "NoDaughter", [
		"Maren: A house nobody lived in. A bow nobody drew.",
		"Maren: There was never a Wren. Then why does he want us at that lodge?",
	])
	_connect(met, &"completed", doubt, &"play")
	_step(quest, "Follow the road to the lodge", "manual")
	_gate(_story, "RoadOn", ["hollow_searched"], {"show": [exit]})
	_finish(_variant_path(HOLLOW))


# --- 4. The Lodge -------------------------------------------------------------------

func _make_lodge() -> void:
	if _exists(LODGE):
		return
	_begin("The Gleaners' Lodge", "GleanersLodge", {"size": Vector2i(64, 112), "seed": 53, "ground": "b1_ground", "patch": "b2_trees",
			"cliff": "b1_cliff",
			"paths": [{"points": [Vector2(0, -40), Vector2(4, -10), Vector2(-4, 20), Vector2(0, 40)], "width": 2.6, "tile": "b1_path"}],
			"river": {"points": [Vector2(-40, 40), Vector2(40, 37)], "width": 3.0}}, "night", Vector3(0, 0, -39))
	var lodge := _group(_story, "Lodge")
	_box(lodge, "NorthWall", Vector3(0, 0, -46), Vector3(16, 4, 0.6), _timber)
	_box(lodge, "WestWall", Vector3(-8, 0, -39), Vector3(0.6, 4, 14), _timber)
	_box(lodge, "EastWall", Vector3(8, 0, -39), Vector3(0.6, 4, 14), _timber)
	_box(lodge, "SouthWallWest", Vector3(-5, 0, -32), Vector3(6, 4, 0.6), _timber)
	_box(lodge, "SouthWallEast", Vector3(5, 0, -32), Vector3(6, 4, 0.6), _timber)
	_prop(lodge, "cauldron", Vector3(0, 0, -43), 0.0, 1.2)
	var corwin := _npc(_story, "Corwin", Vector3(0, 0, -44), 0.0, "corwin", "Corwin Hale", [])
	var jory := _npc(_story, "Jory", Vector3(2, 0, -30), PI, "jory", "Jory Wainwright", [], {"on_start": false})
	var horde := _group(_story, "Horde")
	var behind := _spawner(horde, "FromTheWellspring", Vector3(0, 0, -42), [Vector3(0, 0, -26), Vector3(-4, 0, 16), Vector3(0, 0, 30)],
			"skeleton_minion", "skeleton_warrior")
	var flank := _spawner(horde, "FromTheWoods", Vector3(-20, 0, -10), [Vector3(-4, 0, 10), Vector3(0, 0, 30)], "skeleton_warrior", "zealot")
	_waves(horde, 14.0)
	var risen := _group(_story, "TheOneLeftBehind")
	var risen_aldith := _camp(risen, "RisenAldith", Vector3(-3, 0, 4), "risen_aldith", 1, {"on_start": false, "scale": 1.0})
	var risen_nell := _camp(risen, "RisenNell", Vector3(-3, 0, 4), "risen_nell", 1, {"on_start": false, "scale": 1.0})
	var risen_tamsin := _camp(risen, "RisenTamsin", Vector3(-3, 0, 4), "risen_tamsin", 1, {"on_start": false, "scale": 1.0})
	var gate_trigger := _trigger(_story, "LodgeGate", Vector3(0, 0, -29), 3.5)
	var river := _trigger(_story, "TheRiver", Vector3(0, 0, 35), 6.0)
	var exit := _exit(_story, "ToTheWeirs", Vector3(6, 0, 36), FINALE, "", "Along the river, to the weirs")
	var reveal := _scene(_story, "Reveal", [
		"Corwin Hale: You came. I knew you would. Good people always do.",
		"Maren: Where's Wren?",
		"Corwin Hale: There was never a Wren. There was a famine. Two winters. I buried my whole flock with these hands.",
		"Corwin Hale: Then a voice promised them back. And they came back... hungry. Empty. Husks.",
		"Corwin Hale: The Mercy needs strong souls to make them whole. Soldiers. Hunters. Mages. You signed, and your deaths are promised.",
		"Corwin Hale: Don't be afraid. It doesn't hurt for long.",
	], {"Corwin Hale": corwin}, {"on_start": true, "flags": ["lodge_trap_sprung"]})
	var quest := _quest(_story, "The Gleaners' Lodge", "Get out of the lodge alive.")
	var trap := _step(quest, "Hear him out", "manual", null, {"spawners": [behind, flank]})
	_connect(reveal, &"finished", trap, &"complete")
	_connect(reveal, &"finished", corwin, &"despawn")
	var out := _step(quest, "Break out through the lodge gate", "reach", gate_trigger)
	var help := _scene(_story, "JoryHoldsTheGate", [
		"Jory Wainwright: Go! Through here, to the river. They won't follow you into the water.",
		"Jory Wainwright: I'll hold them. My oath can choke on it.",
		"Jory Wainwright: Tell my mother... tell her the debt's paid.",
	], {"Jory Wainwright": jory})
	_connect(out, &"started", jory, &"spawn")
	_connect(out, &"completed", help, &"play")
	_connect(help, &"finished", jory, &"despawn")
	var reached := _step(quest, "Reach the river", "reach", river, {"flags": ["reached_river"]})
	var stops := _scene(_story, "TheDeadStop", [
		"Maren: They stopped. They won't come into the water.",
		"Maren: Running water... Brook. If the whole valley were ringed with it...",
		"Maren: The old weirs. Three of them hold the river back. Break them and the Mercy has nowhere to go.",
	])
	_connect(reached, &"completed", stops, &"play")
	_step(quest, "Follow the river to the weirs", "manual")
	_gate(_story, "RoadOn", ["reached_river"], {"show": [exit]})
	# The hero left behind in Netherby comes back as one of the Risen, and can still say a last word
	for entry: Array in [[risen_aldith, "job_vigil_done", "risen_aldith", "Ser Aldith",
				"Ser Aldith: Mage... the chapel fell. They brought me back wrong. The north weir is the weakest. Go."],
			[risen_nell, "job_debts_done", "risen_nell", "Nell",
				"Nell: Coyne sold me to them in the end. Funny, that. The south weir... the stones are loose. Go."],
			[risen_tamsin, "job_hunt_done", "risen_tamsin", "Tamsin",
				"Tamsin: I went after the pack alone. Should have waited for you. The west weir. Go."]]:
		var gate := _gate(_story, "Risen" + str(entry[3]).replace(" ", ""), ["lodge_trap_sprung"], {"unless": [entry[1]], "show": [entry[0]]})
		var hunt := _quest(_story, "The One Left Behind (%s)" % entry[3], "Someone you couldn't help came back.", false)
		var fall := _step(hunt, "Put %s to rest" % entry[3], "kill", entry[2])
		var words := _scene(_story, "LastWords" + str(entry[3]).replace(" ", ""), [entry[4]], {entry[3]: entry[0]})
		_connect(gate, &"opened", hunt, &"start")
		_connect(fall, &"completed", words, &"play")
	_finish(LODGE)


# --- 5. The Ring of Water -------------------------------------------------------------

func _make_finale() -> void:
	if _exists(FINALE):
		return
	_begin("The Ring of Water", "RingOfWater", {"size": Vector2i(128, 128), "seed": 67, "ground": "b1_ground", "patch": "b1_neutral2",
			"cliff": "b1_cliff", "hills": 2.0,
			"paths": [{"points": [Vector2(0, 46), Vector2(0, 0)], "width": 2.6, "tile": "b1_path"},
				{"points": [Vector2(0, 0), Vector2(-42, -8)], "width": 2.2, "tile": "b1_path"},
				{"points": [Vector2(0, 0), Vector2(0, -44)], "width": 2.2, "tile": "b1_path"},
				{"points": [Vector2(0, 0), Vector2(42, 16)], "width": 2.2, "tile": "b1_path"}],
			"areas": [{"center": Vector2(0, 0), "radius": 10.0, "tile": "b1_base"}],
			"river": {"points": [Vector2(-56, 48), Vector2(56, 45)], "width": 3.5}}, "dusk", Vector3(0, 0, 40))
	var weirs := _group(_story, "Weirs")
	_npc(weirs, "WestWeir", Vector3(-42, 0, -8), 0.0, "weir", "The west weir", [], {"hurt": true})
	_npc(weirs, "NorthWeir", Vector3(0, 0, -44), 0.0, "weir", "The north weir", [], {"hurt": true})
	_npc(weirs, "SouthWeir", Vector3(42, 0, 16), 0.0, "weir", "The south weir", [], {"hurt": true})
	var wellspring := _group(_story, "Wellspring")
	_prop(wellspring, "orbelisk", Vector3(0, 0, 0), 0.0, 1.4)
	var boss := _camp(wellspring, "Corwin", Vector3(0, 0, 3), "corwin_risen", 1, {"on_start": false, "scale": 1.6})
	var horde := _group(_story, "Horde")
	var spawners: Array[CreepSpawner] = []
	for entry: Array in [["ToWest", Vector3(-40, 0, -8)], ["ToNorth", Vector3(0, 0, -42)], ["ToSouth", Vector3(40, 0, 15)]]:
		spawners.append(_spawner(horde, entry[0], Vector3(0, 0, 0), [Vector3(entry[1]) * 0.5, entry[1]], "skeleton_minion", "skeleton_mage"))
	_waves(horde, 16.0)
	var quest := _quest(_story, "The Ring of Water", "Break the three weirs and let the river ring the valley. Then stop Corwin at the Wellspring.")
	var plan := _scene(_story, "ThePlan", [
		"Maren: Three weirs hold the river back: west, north and south.",
		"Maren: Break them and the water rings the valley. The Mercy can't cross it.",
		"Maren: Brook... when they break, you'll have to carry the water in. All of it.",
	], {}, {"on_start": true})
	var listen := _step(quest, "Make a plan", "manual", null, {"spawners": spawners})
	_connect(plan, &"finished", listen, &"complete")
	var breaking := _step(quest, "Break the three weirs", "kill", "weir", {"count": 3, "flags": ["weirs_broken"]})
	var rising := _scene(_story, "TheWaterRises", [
		"Maren: That's all three. Brook, now!",
		"Maren: The water's coming in. To the Wellspring, before it closes!",
	], {}, {"time": "night"})
	_connect(breaking, &"completed", rising, &"play")
	_gate(_story, "CorwinWaits", ["weirs_broken"], {"show": [boss]})
	var fight := _step(quest, "Stop Corwin at the Wellspring", "kill", "corwin_risen", {"flags": ["campaign_done"]})
	var epilogue := _scene(_story, "Epilogue", [
		"Corwin Hale: My flock... they'll be whole now. Won't they...",
		"The Patron: Thank you, Corwin. You did well.",
		"The Patron: There are other valleys. Other fathers. Other hungry winters.",
		"The Patron: Rest now.",
	], {"Corwin Hale": boss, "The Patron": null}, {"travel_to": Campaign.TITLE_SCENE})
	_connect(fight, &"completed", epilogue, &"play")
	_finish(FINALE)


# --- The Pit: the arena ---------------------------------------------------------------------

func _make_pit() -> void:
	if _exists(PIT):
		return
	_begin("The Pit", "ThePit", {"size": Vector2i(64, 64), "seed": 71, "ground": "g1_ground", "patch": "b1_roots",
			"areas": [{"center": Vector2(0, 0), "radius": 15.0, "tile": "g1_trail"}],
			"paths": [{"points": [Vector2(0, 30), Vector2(0, 14)], "width": 3.0, "tile": "g1_path"}]}, "dusk", Vector3(0, 0, 11))
	var bram := _npc(_story, "BramToller", Vector3(4, 0, 15), -0.85 * PI, "pitmaster", "Captain Bram Toller", [])
	# The ring: a fence with two gates (north, where they come in; south, the way out), torches, the crowd's crates
	var ring := _group(_story, "Ring")
	# A piece is 2.06 m long along its own X: it lies along the ring (yaw = angle, the tangent) and the
	# 52 of them close it with no gap (a chord of 2.05 m at this radius)
	for i in 52:
		var angle := TAU * i / 52.0
		var at := Vector3(sin(angle), 0.0, cos(angle)) * 17.0
		if absf(at.x) < 3.5:
			continue  # the gates
		_kit(ring, "village/Prop_WoodenFence_Single", at, angle, 1.0, true)
	for at: Vector3 in [Vector3(-3.5, 0, -17), Vector3(3.5, 0, -17), Vector3(-3.5, 0, 17), Vector3(3.5, 0, 17), Vector3(-15, 0, 0), Vector3(15, 0, 0)]:
		_torch(ring, at)
	for at: Vector3 in [Vector3(-20, 0, 6), Vector3(-21, 0, 9), Vector3(20, 0, -5), Vector3(19, 0, 10), Vector3(-19, 0, -10)]:
		_kit(ring, "village/Prop_Crate", at, randf() * TAU, 1.0, true)
	_kit(ring, "village/Prop_Wagon", Vector3(22, 0, 14), 0.4, 1.0, true)
	_kit(ring, "dungeon/Banner", Vector3(0, 0, -19), 0.0, 1.5, false)
	# The gate the rounds come through, its lane leading into the ring
	var gate := _spawner(_story, "Gate", Vector3(0, 0, -16), [Vector3(0, 0, -6), Vector3(0, 0, 8)], "skeleton_minion")  # the enemy team: they come at you
	var waves := _waves(_story, 999.0)  # nothing on a timer; the arena sends the rounds (and their heroes) itself
	waves.first_wave_delay = 99999.0
	var recovery := _marker(_story, "Recovery", Vector3(0, 0, 21))
	var arena := ArenaChallenge.new()
	arena.gate = gate
	arena.recovery_spot = recovery
	var modifier := func(name: String) -> MonsterModifier: return load("res://data/modifiers/%s.tres" % name)
	var unit := func(name: String) -> UnitDefinition: return load("res://data/units/%s.tres" % name)
	var rounds: Array[ArenaRound] = []
	for entry: Array in [
			["Husks", "A warm-up: four husks, nothing clever. Keep Brook between them and Maren.",
				["skeleton_minion", "skeleton_minion", "skeleton_minion", "skeleton_minion"], 0, [], 0.0, "", 6],
			["The Burning Ones", "Fire Enchanted: where one falls, the ground burns a moment later. Kill it, then step away.",
				["skeleton_warrior", "skeleton_warrior", "skeleton_warrior"], 0, ["fire_enchanted"], 0.0, "", 10],
			["Bloodsuckers", "Vampiric: their hits heal them. Burst them down; don't trade blows.",
				["skeleton_warrior", "skeleton_warrior", "skeleton_mage", "skeleton_mage"], 0, ["vampiric"], 0.0, "", 12],
			["Frost and Fury", "Extra Fast and Cold Enchanted: they close the gap and chill you. You can't outrun them; fight.",
				["skeleton_rogue", "skeleton_rogue", "skeleton_rogue"], 1, ["extra_fast", "cold_enchanted"], 0.0, "", 15],
			["The Legionnaire", "A sellsword with real tricks: he taunts, he charges. Click him and read what he does.",
				["skeleton_minion", "skeleton_minion"], 1, [], 0.0, "heracles", 25],
			["Grand Melee", "Anything goes: some of them are champions. Read the names over their heads.",
				["skeleton_warrior", "skeleton_warrior", "skeleton_rogue", "skeleton_rogue", "skeleton_mage", "skeleton_mage"], 2, [], 0.5, "", 35]]:
		var round := ArenaRound.new()
		round.title = entry[0]
		round.hint = entry[1]
		for name: String in entry[2]:
			round.creatures.append(unit.call(name))
		round.level_bonus = entry[3]
		for name: String in entry[4]:
			round.modifiers.append(modifier.call(name))
		round.champion_chance = entry[5]
		if not (entry[6] as String).is_empty():
			round.hero = unit.call(entry[6])
		round.prize = entry[7]
		rounds.append(round)
	arena.rounds = rounds
	_node(_story, arena, "Arena")
	_exit(_story, "ToNetherby", Vector3(0, 0, 24), VILLAGE, "Story/Arrivals/FromRoad", "Back to Netherby")
	_gate(_story, "OnceADay", [], {"reversible": true, "flags": ["pit_today"]})
	var rules := _scene(_story, "TheRules", [
		"Captain Bram Toller: My lads drag the dead in off the road and let them through that gate, a few at a time.",
		"Captain Bram Toller: Six rounds, each worse than the last. Win one, you're paid on the spot. Walk out between rounds, you keep it.",
		"Captain Bram Toller: Some of them come back wrong. Burning, quick, thirsty. Look at one before you swing; it'll tell you what it is.",
		"Maren: And if we fall?",
		"Captain Bram Toller: Then my lads drag you out instead. Nobody dies in my pit unless they paid to.",
	], {"Captain Bram Toller": bram}, {"on_start": true, "once": false})  # every visit: it starts the rounds
	_connect(rules, &"finished", arena, &"start")
	var paid := _scene(_story, "PaidOut", [
		"Captain Bram Toller: The crowd liked that. Come back tomorrow; I'll find worse.",
	], {"Captain Bram Toller": bram}, {"once": false})
	_connect(arena, &"finished", paid, &"play")
	_finish(PIT)


## A torch on a post, lit: the dungeon kit's torch with a warm light that flickers a little.
func _torch(parent: Node, at: Vector3) -> Node3D:
	var torch := _kit(parent, "dungeon/Torch", at, 0.0, 1.6, false)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.62, 0.3)
	light.light_energy = 2.2
	light.omni_range = 8.0
	light.shadow_enabled = false
	light.position = Vector3(0, 1.4, 0)
	light.name = "Light"
	torch.add_child(light)
	light.owner = _root
	return torch


## A campfire: the dungeon kit's woodfire, lit.
func _campfire(parent: Node, at: Vector3) -> Node3D:
	var fire := _kit(parent, "dungeon/Woodfire", at, 0.0, 1.2, false)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.25)
	light.light_energy = 2.8
	light.omni_range = 10.0
	light.position = Vector3(0, 0.8, 0)
	light.name = "Light"
	fire.add_child(light)
	light.owner = _root
	return fire


## A piece of a kit (assets/environment/<kit>/<name>.glb: the village or dungeon kits) on the map.
func _kit(parent: Node, file: String, at: Vector3, yaw := 0.0, scale := 1.0, blocks := false) -> Node3D:
	var prop: Node3D = (load("res://assets/environment/%s.glb" % file) as PackedScene).instantiate()
	prop.set_script(MAP_PROP)
	prop.set("blocks_movement", blocks)
	prop.scale = Vector3.ONE * scale
	return _node(parent, prop, file.get_file() + str(parent.get_child_count()), at, yaw) as Node3D


# --- The prologue as a wild map (the road north, generated) ---------------------------------

## The Broken Road on a planned map (DIRECTION.md 5): the wreck, the driver's lantern, the pedlar's fire, the
## field of the dead and the farm along a road north; a branch to the crater (the meme staff), one to the
## overturned cart; the driver's footprints as pale circles on the road, one set to the lantern and two after it.
## The story is the hand-built prologue's (_story_prologue), placed by the plan.
func _make_road() -> void:
	if _exists(_variant_path(ROAD)):
		return
	var size := Vector2i(208, 208)
	var stops: Array[String] = ["Start", "Lantern", "Pedlar", "Field", "Farm", "Netherby"]
	var laid := _plan(size, 11 + _variant * 101, stops, ["Shrine"], "g1_trail", "b1_roots", "north", [["Pedlar", ["Crater"], 3], ["Field", ["Cart"], 2]])
	var plan: RefCounted = laid[0]
	var spec := {"size": size, "seed": 11 + _variant * 101, "ground": "g1_ground", "patch": "g2_trees", "cliff": "g1_cliff", "hills": 1.8}
	spec.merge(laid[1])
	var places: Dictionary = plan.places
	_begin("The Broken Road", "TheBrokenRoad", spec, "night", places["Start"] + Vector3(2, 0, 3))
	var maren: Array[UnitDefinition] = [load("res://data/units/maren.tres")]
	_root.set("starting_party", maren)
	(_root.get_node("Party") as PartyInventory).starting_items = load("res://data/items/story_start_kit.tres")
	_fill(plan, "road")
	var start: Vector3 = places["Start"]
	var lantern: Vector3 = places["Lantern"]
	var pedlar_fire: Vector3 = places["Pedlar"]
	var field: Vector3 = places["Field"]
	var farm: Vector3 = places["Farm"]

	# The wreck (your carriage, as a preset), and the axle that was sawn
	_preset(_story, "carriage", start + Vector3(-3, 0, 0), 0.0)
	var axle := _npc(_story, "TheAxle", start + Vector3(-1.5, 0, 2.5), 0.3, "clue", "The carriage", [
		"The rear axle has snapped clean through.",
		"No... not snapped. Sawn halfway, then left to break on the first bad rut.",
		"The driver's seat is empty. His coat is still on it.",
	], {"scale": 0.5})
	# The driver's footprints: one set to where his lantern stands, two from there (someone met him)
	_footprints(plan, "Start", "Lantern", 1)
	_footprints(plan, "Lantern", "Pedlar", 2)
	_preset(_story, "lantern", lantern + Vector3(2, 0, 0), 0.4)

	var fights := _group(_story, "Fights")
	var mid := func(a: Vector3, b: Vector3, t: float) -> Vector3: return a.lerp(b, t) + Vector3(6, 0, 0)
	_camp(fights, "HusksOnTheTracks", mid.call(start, lantern, 0.5), "husk", 2, {"gold": 2})
	var wrong_one: Vector3 = mid.call(lantern, pedlar_fire, 0.55)
	_camp(fights, "TheWrongOne", wrong_one, "risen_brute", 1, {"modifiers": ["extra_strong"], "gold": 6})
	_camp(fights, "TheFieldOfTheDead", field + Vector3(0, 0, -4), "husk", 5, {"champion": 0.5, "gold": 3})
	var graves := _group(_story, "FieldOfTheDead")
	graves.position = field
	_piece("graves", graves, Vector3.ZERO, plan.rng)

	# The pedlar's fire: your campfire (the preset), Hesk, his wares
	_preset(_story, "bonfire", pedlar_fire + Vector3(-2, 0, -2), 0.0)
	var pedlar := _npc(_story, "Pedlar", pedlar_fire + Vector3(1.5, 0, -1.5), PI * 0.8, "pedlar", "Hesk the pedlar", [
		"Charms, gloves, a ring or two. Cheaper than a funeral.",
		"Strangest thing, last summer: a bang off past the hill, loud as the end of the world. Somebody shouting first, long and proud. Didn't go look.",
		"Charms, gloves, a ring or two.",
	])
	var wares := Vendor.new()
	wares.title = "Hesk the pedlar"
	wares.purse = 30
	wares.markup = 1.25
	var stock: Array[ItemDefinition] = [LootRoller.roll(load("res://data/items/work_gloves.tres"), 2, ItemDefinition.Rarity.MAGIC),
			LootRoller.roll(load("res://data/items/iron_ring.tres"), 2, ItemDefinition.Rarity.MAGIC)]
	wares.stock = stock
	_node(_story, wares, "PedlarsWares")
	wares.host = pedlar

	# Off the road: the overturned cart, and the crater with the staff of someone who knew one spell
	if places.has("Cart"):
		var cart_at: Vector3 = places["Cart"]
		_kit(_story, "village/Prop_Wagon", cart_at, 1.9, 1.0, true).rotation.z = 0.5
		var chest := Chest.new()
		chest.random_items = 1
		chest.better_odds = true
		chest.gold = 8
		_node(_story, chest, "CartChest", cart_at + Vector3(-5, 0, 3), 0.4)
		_camp(fights, "ByTheCart", cart_at + Vector3(4, 0, -4), "ghoul", 2, {"gold": 3})
	if places.has("Crater"):
		var crater := _group(_story, "TheCrater")
		crater.position = places["Crater"]
		var scorch := StandardMaterial3D.new()
		scorch.albedo_color = Color(0.12, 0.09, 0.08)
		scorch.roughness = 1.0
		for ring in 3:
			var disc := CylinderMesh.new()
			disc.top_radius = 7.0 - ring * 2.2
			disc.bottom_radius = disc.top_radius
			disc.height = 0.02
			disc.material = scorch
			var mark := MeshInstance3D.new()
			mark.mesh = disc
			_node(crater, mark, "Scorch%d" % ring, Vector3(0, _ground_height(_root, crater.position) + 0.04 + ring * 0.01, 0))
		_prop(crater, "skull_pile", Vector3(4, 0, 3), 0.6, 0.8, false)
		var staff_chest := Chest.new()
		staff_chest.items.append(load("res://data/items/crimson_demons_staff.tres"))
		_node(crater, staff_chest, "HalfBuried", Vector3.ZERO, 0.3)

	# The farm: a house, ash marks around it, the ledger inside (a checkpoint), the root cellar in the yard
	var homestead := _group(_story, "Farm")
	homestead.position = farm
	_kit_house(homestead, "Farmhouse", Vector3(0, 0, -6), 0.0, 4, 4)
	_preset(homestead, "stump", Vector3(-7, 0, 2), 0.0)
	_preset(homestead, "fence", Vector3(7, 0, 3), 0.0)
	var marks := _group(_story, "Markings")
	var mark_material := StandardMaterial3D.new()
	mark_material.albedo_color = Color(0.85, 0.85, 0.7)
	mark_material.emission_enabled = true
	mark_material.emission = Color(0.6, 0.65, 0.45)
	var mark_mesh := CylinderMesh.new()
	mark_mesh.top_radius = 0.8
	mark_mesh.bottom_radius = 0.8
	mark_mesh.height = 0.03
	mark_mesh.material = mark_material
	for offset: Vector3 in [Vector3(5, 0, 1), Vector3(-5, 0, 0), Vector3(6, 0, -9), Vector3(-2, 0, 3)]:
		var mark := MeshInstance3D.new()
		mark.mesh = mark_mesh
		var at := farm + offset
		at.y = _ground_height(_root, at) + 0.05
		_node(marks, mark, "Mark", at)
	var checkpoint := Checkpoint.new()
	checkpoint.title = "The farm (checkpoint)"
	_node(_story, checkpoint, "FarmCheckpoint", farm + Vector3(0, 0, 1))
	# Lore only (it was a shortcut past the tutorial, which isn't in the way): in the yard, where it can be seen and read
	_npc(_story, "Ledger", farm + Vector3(-3.5, 0, 3), 0.3, "ledger", "The farm's ledger", [
		"Wheat sold, wheat owed. Rows of careful figures, year after year.",
		"The last page is different. The ink is darker, the hand shaking:",
		"'They pay for the dead now. Forty silver a soul. God forgive me, I signed for all of us.'",
	], {"scale": 0.5})
	var cellar := _npc(_story, "RootCellar", farm + Vector3(3, 0, 2), 0.0, "cellar", "The root cellar",
			["A hatch in the ground, the boards grey with age. Under it: turnips, soft but good, and a crock of honey, still sealed."])
	var supper := Supper.new()
	supper.meal = load("res://data/meals/honey_cakes.tres")
	_node(_story, supper, "FirstSupper")
	var tutorial: Node = (load("res://scenes/tutorial/tutorial.tscn") as PackedScene).instantiate()
	_root.add_child(tutorial)
	tutorial.owner = _root

	var shelter := _trigger(_story, "TheFarm", farm, 8.0)
	var road := _exit(_story, "ToNetherby", places["Netherby"], VILLAGE, "Story/Arrivals/FromRoad", "The road to Netherby")
	_scene(_story, "Waking", [
		"Maren: Brook? Brook, you're all right.",
		"Maren: The driver's gone. The horses too.",
		"Maren: Nothing for it. We walk until we find a roof.",
	], {}, {"on_start": true})
	var quest := _quest(_story, "The Broken Road", "Stranded on the road in the night, with Brook. Find out where the driver went, and a roof.")
	var looked := _step(quest, "Look at the carriage", "talk", axle)
	var followed := _step(quest, "Follow the driver's footprints up the road", "reach", _trigger(_story, "TheTracks", lantern, 5.0))
	var to_pedlar := _step(quest, "Follow the two sets of footprints to the fire ahead", "reach", _trigger(_story, "ThePedlarsFire", pedlar_fire, 6.0))
	var found := _step(quest, "Find shelter: the empty farm up the road, past the field", "reach", shelter)
	var fed := _step(quest, "Find something for supper: the root cellar, a hatch in the yard, by the farmhouse door (right-click it)", "talk", cellar)
	var rest := _step(quest, "Rest at the farm", "manual")
	_step(quest, "Take the road to Netherby", "manual")
	_connect(looked, &"completed", _scene(_story, "SawnAxle", [
		"Maren: Sawn. Someone wanted us stopped here, in the dark.",
		"Maren: And the driver's footprints go up the road. Not running. Walking.",
	]), &"play")
	_connect(followed, &"completed", _scene(_story, "TheLantern", [
		"Maren: His lantern. Put out, and set down neatly.",
		"Maren: Two sets of boots from here. Someone met him, and they walked on together.",
		"Maren: Brook, stay close. Whatever's on this road, he wasn't afraid of it.",
	]), &"play")
	var warn := _scene(_story, "TheWrongOne", [
		"Maren: That one's wrong. Bigger than the rest, and the way it moves...",
		"Hint: Click an enemy before you fight it. Its name, level and traits show at the top, and a card says what each trait does.",
	], {"Hint": null})
	_connect(_trigger(_story, "NearTheWrongOne", wrong_one, 12.0), &"reached", warn, &"play")
	_connect(to_pedlar, &"completed", _scene(_story, "ThePedlar", [
		"Hesk the pedlar: Easy, easy! Just a pedlar. Sit, if you like; the fire's free.",
		"Maren: A driver came this way tonight. With someone.",
		"Hesk the pedlar: Aye. Your Jory, was it? With a priestly sort, grey coat, kind voice. Off to the valley road, both of them, in a hurry.",
		"Hesk the pedlar: There's an empty farm up the road. Sleep there, not out here. Mind the field before it; the dead walk there at night.",
		"Hesk the pedlar: And if you've coin, I've gloves and a ring. If you've things to sell, I've a little coin.",
	], {"Hesk the pedlar": pedlar}), &"play")
	_connect(found, &"completed", _scene(_story, "TheFarmAtNight", [
		"Maren: Nobody has lived here for a while.",
		"Maren: Marks on the walls... wheat sheaves, drawn in ash. Dozens of them.",
		"Maren: We'll sleep here. But not hungry. There has to be a cellar.",
	]), &"play")
	var eat := _scene(_story, "SupperAtTheFarm", [
		"Maren: Turnips, soft but good. A crock of honey, still sealed. Someone meant to come back for this.",
		"Maren: Honey cakes, Brook. Like the ones at home. Well... nearly.",
		"Maren: Keep watch. We go on at first light.",
	], {}, {"time": "dawn", "flags": ["road_rested", "rested"]})
	_connect(fed, &"completed", eat, &"play")
	_connect(eat, &"finished", supper, &"serve")
	_connect(eat, &"finished", rest, &"complete")
	_gate(_story, "Morning", ["road_rested"], {"show": [road]})
	_finish(_variant_path(ROAD))


## A preset (tools/presets/extract_presets.gd: a group of props built by hand, scenes/presets) on the map.
func _preset(parent: Node, preset: String, at: Vector3, yaw := 0.0) -> Node3D:
	var scene := load(PRESETS + preset + ".tscn") as PackedScene
	if scene == null:
		push_warning("no preset " + preset)
		return null
	var node: Node3D = scene.instantiate()
	at.y = _ground_height(_root, at)  # props that don't settle on the ground keep their height above it
	return _node(parent, node, preset.to_pascal_case() + str(parent.get_child_count()), at, yaw) as Node3D


## Boot prints along the road from place `from` to place `to`: pale circles, left and right, `walkers` side by
## side.
func _footprints(plan: RefCounted, from: String, to: String, walkers: int) -> void:
	var a: int = plan.road.find(plan.cell_of(from))
	var b: int = plan.road.find(plan.cell_of(to))
	if a < 0 or b < 0:
		push_warning("footprints: %s or %s isn't on the road" % [from, to])
		return
	var points: Array[Vector3] = []
	for i in range(a, b + 1):
		points.append(plan.world(plan.road[i]))
	points[0] = plan.places[from]
	points[points.size() - 1] = plan.places[to]
	var transforms: Array[Transform3D] = []
	var stride := 0.85
	var left := true
	for i in points.size() - 1:
		var p: Vector3 = points[i]
		var q: Vector3 = points[i + 1]
		var length := p.distance_to(q)
		var along := (q - p).normalized()
		var side := along.cross(Vector3.UP).normalized()
		var yaw := atan2(along.x, along.z)
		var t := 0.0
		while t < length:
			for walker in walkers:
				var lane := (walker - (walkers - 1) * 0.5) * 0.9
				var at := p + along * (t + walker * 0.4) + side * (lane + (0.17 if left else -0.17))
				at.y = _ground_height(_root, at) + 0.04
				transforms.append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(0.75, 1, 1.25)), at))
			left = not left
			t += stride
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.18
	mesh.bottom_radius = 0.18
	mesh.height = 0.02
	mesh.radial_segments = 10
	var material := StandardMaterial3D.new()  # pale, faintly glowing, like the ash marks: they must read at night
	material.albedo_color = Color(0.78, 0.72, 0.55)
	material.emission_enabled = true
	material.emission = Color(0.45, 0.42, 0.3)
	material.roughness = 1.0
	mesh.material = material
	# One node a print, the mesh shared: a MultiMesh's instances aren't kept when the generator runs headless
	var prints := _group(_story, "Footprints%sTo%s" % [from, to])
	for i in transforms.size():
		var print_node := MeshInstance3D.new()
		print_node.mesh = mesh
		print_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_node(prints, print_node, "Print%d" % i)
		print_node.transform = transforms[i]


# --- The prologue: the broken road ------------------------------------------------------

func _story_prologue() -> void:
	var root: Node3D = (load(PROLOGUE) as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if root.has_node("Story"):
		if not _rewrite_story:
			print("kept the prologue's Story")
			root.free()
			return
		root.get_node("Story").free()
	_root = root
	var maren: Array[UnitDefinition] = [load("res://data/units/maren.tres")]
	root.set("starting_party", maren)
	root.set("map_name", "The Broken Road")
	(root.get_node("Party") as PartyInventory).starting_items = load("res://data/items/story_start_kit.tres")  # off the carriage: little
	# The farm's ledger: figures, and a note; destroying it skips the tutorial and pays (quietly)
	var ledger := root.get_node("WellCheckpoint/ledger") as NeutralSpawn
	ledger.gold = 40
	if ledger.dialogue != null:
		ledger.dialogue.speaker = "The farm's ledger"
		ledger.dialogue.lines = PackedStringArray([
			"Wheat sold, wheat owed. Rows of careful figures, year after year.",
			"The last page is different. The ink is darker, the hand shaking:",
			"'They pay for the dead now. Forty silver a soul. God forgive me, I signed for all of us.'",
		])
	_story = _node(root, Node3D.new(), "Story") as Node3D
	var clock := TimeOfDay.new()
	_node(_story, clock, "TimeOfDay")
	var farm: Vector3 = (root.get_node("WellCheckpoint") as Node3D).position
	# The wreck: the axle was sawn
	var axle := _npc(_story, "TheAxle", Vector3(-70.0, 0.0, 73.0), 0.3, "clue", "The carriage", [
		"The rear axle has snapped clean through.",
		"No... not snapped. Sawn halfway, then left to break on the first bad rut.",
		"The driver's seat is empty. His coat is still on it.",
	], {"scale": 0.5})
	# Marks on the farm's walls and yard (placeholders: pale discs until there are decals)
	var marks := _group(_story, "Markings")
	var mark_material := StandardMaterial3D.new()
	mark_material.albedo_color = Color(0.85, 0.85, 0.7)
	mark_material.emission_enabled = true
	mark_material.emission = Color(0.6, 0.65, 0.45)
	var mark_mesh := CylinderMesh.new()
	mark_mesh.top_radius = 0.8
	mark_mesh.bottom_radius = 0.8
	mark_mesh.height = 0.03
	mark_mesh.material = mark_material
	for offset: Vector3 in [Vector3(4, 0.05, 7), Vector3(-5, 0.05, 6), Vector3(6, 0.05, -2), Vector3(-2, 0.05, 9)]:
		var mark := MeshInstance3D.new()
		mark.mesh = mark_mesh
		var at: Vector3 = farm + offset
		at.y = _ground_height(root, at) + 0.05  # on the drawn ground, which stands above the gameplay plane
		_node(marks, mark, "Mark", at)
	var shelter := _trigger(_story, "TheFarm", farm, 7.0)
	var road := _exit(_story, "ToNetherby", _walkable_near(root, farm + Vector3(26, 0, -14)), VILLAGE, "Story/Arrivals/FromRoad",
			"The road to Netherby")
	# The road, the long way round (DIRECTION.md 7): the driver's tracks north, the bootprints east along
	# the hill, a pedlar's fire, the field of the dead, then the farm. First fights all along it.
	var tracks_end := _walkable_near(root, Vector3(-68, 0, 10))
	var pedlar_fire := _walkable_near(root, Vector3(18, 0, -12))
	var fights := _group(_story, "Fights")
	_camp(fights, "HusksAtTheHorse", _walkable_near(root, Vector3(-64, 0, 50)), "skeleton_minion", 2, {"gold": 2})
	_camp(fights, "OnTheTracks", _walkable_near(root, Vector3(-70, 0, 26)), "skeleton_minion", 3, {"gold": 2})
	var wrong_one := _walkable_near(root, Vector3(-44, 0, -4))
	_camp(fights, "TheWrongOne", wrong_one, "skeleton_warrior", 1, {"modifiers": ["extra_strong"], "gold": 6})
	_camp(fights, "HillRoad", _walkable_near(root, Vector3(-14, 0, -8)), "skeleton_minion", 4, {"gold": 2})
	_camp(fights, "TheFieldOfTheDead", _walkable_near(root, Vector3(2, 0, 18)), "skeleton_minion", 5, {"champion": 0.5, "gold": 3})
	_camp(fights, "ByTheCart", _walkable_near(root, Vector3(34, 0, 36)), "skeleton_mage", 2, {"gold": 3})
	# Off the road: an overturned cart, and something in it
	var cart_at := _walkable_near(root, Vector3(38, 0, 40))
	_kit(_story, "village/Prop_Wagon", cart_at, 1.9, 1.0, true).rotation.z = 0.5
	var chest := Chest.new()
	chest.random_items = 1
	chest.better_odds = true
	chest.gold = 8
	_node(_story, chest, "CartChest", cart_at + Vector3(-5.0, 0, 3.0), 0.4)  # clear of the wagon (4 m long)
	# Out of the way, for those who know (DIRECTION.md 6): a crater in the far north-east, scorched in a ring, and
	# in it the staff of someone who knew one spell
	var crater_at := _walkable_near(root, Vector3(58, 0, -58))
	var crater := _group(_story, "TheCrater")
	crater.position = crater_at
	var scorch := StandardMaterial3D.new()
	scorch.albedo_color = Color(0.12, 0.09, 0.08)
	scorch.roughness = 1.0
	for ring in 3:
		var disc := CylinderMesh.new()
		disc.top_radius = 7.0 - ring * 2.2
		disc.bottom_radius = disc.top_radius
		disc.height = 0.02
		disc.material = scorch
		var mark := MeshInstance3D.new()
		mark.mesh = disc
		_node(crater, mark, "Scorch%d" % ring, Vector3(0, _ground_height(root, crater_at) + 0.04 + ring * 0.01, 0))
	_prop(crater, "skull_pile", Vector3(4, 0, 3), 0.6, 0.8, false)
	var staff_chest := Chest.new()
	staff_chest.items.append(load("res://data/items/crimson_demons_staff.tres"))
	_node(crater, staff_chest, "HalfBuried", Vector3(0, 0, 0), 0.3)

	# The pedlar's fire: a trader on the road, small wares, a small purse
	var camp := _group(_story, "PedlarsCamp")
	camp.position = pedlar_fire
	_campfire(camp, Vector3.ZERO)
	_kit(camp, "village/Prop_Crate", Vector3(2.2, 0, 1.0), 0.3, 1.0, true)
	_kit(camp, "dungeon/Barrel", Vector3(-2.0, 0, 1.4), 0.0, 1.0, true)
	var pedlar := _npc(_story, "Pedlar", pedlar_fire + Vector3(1.5, 0, -1.5), PI * 0.8, "pedlar", "Hesk the pedlar", [
		"Charms, gloves, a ring or two. Cheaper than a funeral.",
		"Strangest thing, last summer: a bang off to the north-east, loud as the end of the world. Somebody shouting first, long and proud. Didn't go look.",
		"Charms, gloves, a ring or two.",
	])
	var wares := Vendor.new()
	wares.title = "Hesk the pedlar"
	wares.purse = 30
	wares.markup = 1.25
	var stock: Array[ItemDefinition] = [LootRoller.roll(load("res://data/items/work_gloves.tres"), 2, ItemDefinition.Rarity.MAGIC),
			LootRoller.roll(load("res://data/items/iron_ring.tres"), 2, ItemDefinition.Rarity.MAGIC)]
	wares.stock = stock
	wares.host = pedlar
	_node(_story, wares, "PedlarsWares")
	# The farm's root cellar: the first supper
	var cellar := _npc(_story, "RootCellar", _walkable_near(root, farm + Vector3(10, 0, -4)), 0.0, "cellar", "The root cellar",
			["A hatch in the ground, the boards grey with age. Under it: turnips, soft but good, and a crock of honey, still sealed."])  # lines: a neutral without any is followed, not talked to (commander.gd)
	var supper := Supper.new()
	supper.meal = load("res://data/meals/honey_cakes.tres")
	_node(_story, supper, "FirstSupper")

	_scene(_story, "Waking", [
		"Maren: Brook? Brook, you're all right.",
		"Maren: The driver's gone. The horses too.",
		"Maren: Nothing for it. We walk until we find a roof.",
	], {}, {"on_start": true})
	var quest := _quest(_story, "The Broken Road", "Stranded on the road in the night, with Brook. Find out where the driver went, and a roof.")
	var looked := _step(quest, "Look at the carriage", "talk", axle)
	var to_tracks := _trigger(_story, "TheTracks", tracks_end, 5.0)
	var followed := _step(quest, "Follow the driver's tracks north", "reach", to_tracks)
	var to_pedlar := _trigger(_story, "ThePedlarsFire", pedlar_fire, 6.0)
	var east := _step(quest, "Follow the bootprints east, along the hill", "reach", to_pedlar)
	var found := _step(quest, "Find shelter: the empty farm south-west of the pedlar's fire", "reach", shelter)
	var fed := _step(quest, "Find something for supper: the root cellar, a hatch in the yard, by the farmhouse door (right-click it)", "talk", cellar)
	var rest := _step(quest, "Rest at the farm", "manual")
	_step(quest, "Take the road to Netherby", "manual")
	_connect(looked, &"completed", _scene(_story, "SawnAxle", [
		"Maren: Sawn. Someone wanted us stopped here, in the dark.",
		"Maren: And the driver's tracks go north. Not running. Walking.",
	]), &"play")
	_connect(followed, &"completed", _scene(_story, "TheLantern", [
		"Maren: His lantern. Put out, and set down neatly.",
		"Maren: Two sets of boots here. Someone met him, and they walked off east together, along the hill.",
		"Maren: Brook, stay close. Whatever's on this road, he wasn't afraid of it.",
	]), &"play")
	var hint := _trigger(_story, "NearTheWrongOne", wrong_one + Vector3(0, 0, 8), 9.0)
	var warn := _scene(_story, "TheWrongOne", [
		"Maren: That one's wrong. Bigger than the rest, and the way it moves...",
		"Hint: Click an enemy before you fight it. Its name, level and traits show at the top, and a card says what each trait does.",
	], {"Hint": null})
	_connect(hint, &"reached", warn, &"play")
	_connect(east, &"completed", _scene(_story, "ThePedlar", [
		"Hesk the pedlar: Easy, easy! Just a pedlar. Sit, if you like; the fire's free.",
		"Maren: A driver came this way tonight. With someone.",
		"Hesk the pedlar: Aye. Your Jory, was it? With a priestly sort, grey coat, kind voice. Off to the valley road, both of them, in a hurry.",
		"Hesk the pedlar: There's an empty farm south-west of here. Sleep there, not out on the road. Mind the field before it; the dead walk there at night.",
		"Hesk the pedlar: And if you've coin, I've gloves and a ring. If you've things to sell, I've a little coin.",
	], {"Hesk the pedlar": pedlar}), &"play")
	var night := _scene(_story, "TheFarmAtNight", [
		"Maren: Nobody has lived here for a while.",
		"Maren: Marks on the walls... wheat sheaves, drawn in ash. Dozens of them.",
		"Maren: We'll sleep here. But not hungry. There has to be a cellar.",
	])
	_connect(found, &"completed", night, &"play")
	var eat := _scene(_story, "SupperAtTheFarm", [
		"Maren: Turnips, soft but good. A crock of honey, still sealed. Someone meant to come back for this.",
		"Maren: Honey cakes, Brook. Like the ones at home. Well... nearly.",
		"Maren: Keep watch. We go on at first light.",
	], {}, {"time": "dawn", "flags": ["road_rested", "rested"]})
	_connect(fed, &"completed", eat, &"play")
	_connect(eat, &"finished", supper, &"serve")
	_connect(eat, &"finished", rest, &"complete")
	_gate(_story, "Morning", ["road_rested"], {"show": [road]})
	_save(root, PROLOGUE)


## The drawn ground's height at `at` (the nearest terrain vertex): where decals and markings go.
func _ground_height(root: Node, at: Vector3) -> float:
	var data := (root.get_node("NavigationRegion3D/Terrain") as Terrain).data
	var half := Vector2(data.size) * 0.5
	var x := clampi(int(round(at.x + half.x)), 0, data.size.x)
	var z := clampi(int(round(at.z + half.y)), 0, data.size.y)
	return data.heights[data.index(x, z)]


## A walkable spot near `wanted` on the map's terrain: flat, not blocked.
func _walkable_near(root: Node, wanted: Vector3) -> Vector3:
	var terrain := root.get_node("NavigationRegion3D/Terrain") as Terrain
	var data := terrain.data
	var half := Vector2(data.size) * 0.5
	var best := wanted
	var best_score := INF
	for ring in 12:
		for step in 12:
			var angle := TAU * step / 12.0
			var at := wanted + Vector3(cos(angle), 0, sin(angle)) * ring * 2.0
			var cell := Vector2i(int(at.x + half.x), int(at.z + half.y))
			if cell.x < 2 or cell.y < 2 or cell.x > data.size.x - 2 or cell.y > data.size.y - 2:
				continue
			var low := INF
			var high := -INF
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					var h := data.heights[data.index(cell.x + dx, cell.y + dz)]
					low = minf(low, h)
					high = maxf(high, h)
			var blocked := not data.blockers.is_empty() and data.blockers[data.index(cell.x, cell.y)] != 0
			var score := (high - low) * 10.0 + ring * 0.5 + (100.0 if blocked else 0.0)
			if score < best_score:
				best_score = score
				best = at
	return best


# --- The village: Netherby, the hub ----------------------------------------------------

func _story_village() -> void:
	var root: Node3D = (load(VILLAGE) as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if root.has_node("Story"):
		if not _rewrite_story:
			print("kept the village's Story")
			root.free()
			return
		root.get_node("Story").free()
	_root = root
	root.set("map_name", "Netherby")
	_story = _node(root, Node3D.new(), "Story") as Node3D
	_node(_story, TimeOfDay.new(), "TimeOfDay")
	var arrivals := _group(_story, "Arrivals")
	var west := _walkable_near(root, Vector3(-20, 0, 6))
	var east := _walkable_near(root, Vector3(20, 0, 6))
	var north := _walkable_near(root, Vector3(-8, 0, -18))
	var up_the_valley := _walkable_near(root, Vector3(10, 0, -18))
	_marker(arrivals, "FromRoad", _walkable_near(root, Vector3(0, 0, 22)), PI)
	_marker(arrivals, "FromVigil", west + Vector3(3, 0, 0), 0.5 * PI)
	_marker(arrivals, "FromDebts", east - Vector3(3, 0, 0), -0.5 * PI)
	_marker(arrivals, "FromHunt", north + Vector3(0, 0, 3), PI)
	# Brann knows who pays
	var brann := root.get_node("Villagers/Innkeeper") as NeutralSpawn
	brann.definition = _units["brann"]  # the townsfolk's faces, not the KayKit stand-ins
	var scout := root.get_node_or_null("Villagers/Scout") as NeutralSpawn
	if scout != null:
		scout.definition = _units["villager_woman"]
	# A rumor (DIRECTION.md 1): the Twin Brands, two halves out in the valley, joined in the combine grid
	var wat := _npc(_story, "OldWat", _walkable_near(root, Vector3(-7, 0, 7)), 0.6 * PI, "villager_man", "Old Wat", [
		"You've the look of someone who fights for a living. Ever heard of the Twin Brands?",
		"The old road wardens carried them, in my grandfather's day. Two blades: one cold as moonlight, one that never stopped smoking.",
		"The Lightbrand went north with the hunters who never came back. Folk say the ghouls drag their kills' things to their dens.",
		"The Firebrand stayed in Briar's Hollow, in the chapel. Then the Gleaners came and took every bit of steel up there.",
		"Put the two together and you'd have something. Ask Mags; she'd know how they fit.",
		"Still here? The north wood, and the Hollow. Go on.",
	])
	var brands := _quest(_story, "The Twin Brands", "Old Wat's tale: two wardens' blades, lost in the valley. Together, one weapon.", false)
	_step(brands, "Find the Lightbrand: the ghouls of the north wood drag their kills' things off", "item", "lightbrand")
	_step(brands, "Find the Firebrand: the Gleaners took the Hollow's steel", "item", "firebrand")
	_step(brands, "Join them: both blades in the combine grid (I, the inventory)", "item", "twin_brands",
			{"message": "The Twin Brands, whole again."})
	_connect(wat, &"talked", brands, &"start")
	var work := Dialogue.new()
	work.speaker = "Brann the Innkeeper"
	work.lines = PackedStringArray([
		"Welcome to the Sleeping Boar. You look like the road chewed you up and spat you out.",
		"No coin? Then you'll want work. There's always work in Netherby these days.",
		"Acolyte Bede needs swords at the chapel. Old Fenn needs his granddaughter found. Young Hob's asking after anyone who can track.",
		"A bed's twelve silver a night, supper extra. Come back with silver and it's yours.",
	])
	work.repeat_from = 2
	brann.dialogue = work
	var inn := Inn.new()
	inn.title = "A night at the Sleeping Boar"
	inn.price = 12
	inn.meals = _meals.duplicate()
	var clears: Array[StringName] = [&"pit_today"]
	inn.clear_flags = clears
	_node(_story, inn, "SleepingBoar")
	inn.host = brann
	var mags := _npc(_story, "Chandler", _walkable_near(root, Vector3(-3, 0, 12)), PI, "chandler", "Mags the Chandler",
			["Candles, rope, a decent cap. Coin first, mind."])
	var shop := Vendor.new()
	shop.title = "Mags the Chandler"
	var wares: Array[ItemDefinition] = []
	for id in ["militia_sword", "hunting_bow", "leather_cap", "leather_bracers", "boots_of_speed", "ring_of_protection",
			"ring_of_regeneration", "mantle_of_intelligence", "pendant_of_willpower", "chainmail"]:
		wares.append(load("res://data/items/%s.tres" % id))
	shop.stock = wares
	_node(_story, shop, "ChandlersShop")
	shop.host = mags
	# The smith (DIRECTION.md 1): rerolls, tempering, a good line carried from one find to another, for tokens
	var cole := _npc(_story, "Smith", _walkable_near(root, Vector3(-10, 0, 14)), PI * 0.8, "smith", "Tobias Cole, smith", [
		"Bring me what you find out there. I can't make it new, but I can make it better.",
		"Tokens, I call them. A token's a morning at my anvil: fifteen silver, or win them in Bram's Pit.",
		"One token, I'll take a line off a thing and hammer in another. Two, I'll temper it, and all of it grows. Three, I'll take the best of one piece into another, and the rest goes in the fire.",
		"What've you got?",
	], {"repeat_from": 3})
	_kit(_story, "dungeon/Barrel", cole.position + Vector3(2.0, 0, -1.0), 0.0, 1.0, true)
	_campfire(_story, cole.position + Vector3(-2.2, 0, -1.2))  # the forge's fire, until there's a forge
	var forge := Blacksmith.new()
	forge.title = "Tobias Cole, smith"
	_node(_story, forge, "TheForge")
	forge.host = cole
	var pit_spot := _walkable_near(root, Vector3(16, 0, 16))
	_npc(_story, "BramToller", pit_spot + Vector3(-2, 0, 0), -0.5 * PI, "pitmaster", "Captain Bram Toller", [
		"My lads bring the dead in off the road and let them loose in the Pit, a few at a time. Folk bet on it.",
		"Six rounds a night, worse each time, paid on the spot. Once a day, mind. Some of them come back... wrong.",
	])
	var to_pit := _exit(_story, "ToThePit", pit_spot, PIT, "", "The Pit")
	_gate(_story, "PitTonight", [], {"unless": ["pit_today"], "reversible": true, "show": [to_pit]})
	var jobs := _group(_story, "Jobs")
	var bede := _npc(jobs, "AcolyteBede", west + Vector3(5, 0, -2), 0.5 * PI, "bede", "Acolyte Bede", [
		"The chapel of St. Lammas stands by the old cemetery. The dead rise there every night now.",
		"One knight holds the door alone. Ser Aldith. She won't leave it.",
		"Help her see the dawn and the chapel pays what it can. The road west, past the mill.",
	])
	var fenn := _npc(jobs, "OldFenn", east - Vector3(5, 0, 2), -0.5 * PI, "fenn", "Old Fenn", [
		"My granddaughter Nell. She took something from the moneylender, Edith Coyne. A book.",
		"Coyne's men are combing the lanes by the old mill for her. If they find her first...",
		"Get her out of the village and everything I have is yours. It isn't much. The east lanes.",
	])
	var hob := _npc(jobs, "Hob", north + Vector3(2, 0, 5), 0.0, "hob", "Hob", [
		"Tamsin Holt went after the ghouls alone. They took her partner three nights back.",
		"She's the best tracker in the valley, but nobody hunts those things alone.",
		"The council pays for every ghoul. Her trail goes north, into the wood.",
	])
	var to_vigil := _exit(jobs, "ToTheChapel", west, VIGIL, "", "West, to the chapel")
	var to_debts := _exit(jobs, "ToTheLanes", east, DEBTS, "", "East, to the lanes")
	var to_hunt := _exit(jobs, "ToTheWood", north, HUNT, "", "North, into the wood")
	# The work, and the stranger after two jobs
	var main := _quest(_story, "Work for Coin", "Stranded in Netherby without a coin. Find work.")
	var asked := _step(main, "Ask Brann at the Sleeping Boar about work", "talk", brann, {"flags": ["jobs_offered"]})
	_step(main, "Take on two of the jobs", "flag", "jobs_two_done")
	var corwin := _npc(_story, "Corwin", Vector3(2.4, 0, -4.2), PI, "corwin", "Corwin Hale",
			["Please... you're the ones who helped? I need to ask you something."], {"on_start": false})
	var plea := _step(main, "Someone is waiting for you at the Sleeping Boar", "talk", corwin)
	var pitch := [
		"Corwin Hale: Forgive me. You're the ones who help, they say.",
		"Corwin Hale: My name is Corwin Hale. I cut wood in Briar's Hollow, up the valley.",
		"Corwin Hale: My daughter, Wren. Best hunter the Hollow ever had. She fell in with men who come by night, and she went with them.",
		"Maren: Went where?",
		"Corwin Hale: A lodge, deep in the woods. I've saved all my life. Every coin of it is yours if you bring her home.",
	]
	var sign := [
		"Corwin Hale: I wrote it down, so it's honest. Sign here... and here.",
		"Maren: We'll find her.",
	]
	var doubt := [
		"Tamsin: Wren? I know every hunter from here to the river. There's no Wren in the Hollow.",
		"Corwin Hale: She hunted under her mother's name. She never wanted anyone to know she was mine.",
		"Tamsin: ...Maybe.",
	]
	var told := _scene(_story, "TheStrangersPlea", pitch + sign, {"Corwin Hale": corwin},
			{"unless": ["job_hunt_done"], "flags": ["stranger_contract_signed"]})
	var told_doubting := _scene(_story, "TheStrangersPleaDoubted", pitch + doubt + sign, {"Corwin Hale": corwin},
			{"only_if": ["job_hunt_done"], "flags": ["stranger_contract_signed"]})
	_connect(plea, &"completed", told, &"play")
	_connect(plea, &"completed", told_doubting, &"play")
	_step(main, "Go to Briar's Hollow", "manual")
	var to_hollow := _exit(_story, "ToBriarsHollow", up_the_valley, HOLLOW, "", "Up the valley, to Briar's Hollow")
	# The three jobs, offered once Brann has told of them
	var vigil := _job_quest("The Night Vigil", "Help Ser Aldith hold the chapel of St. Lammas until dawn.", bede, "job_vigil_done",
			"Help Ser Aldith at the chapel (west)")
	var debts := _job_quest("Debts of the Living", "Get Old Fenn's granddaughter Nell out of the village alive.", fenn, "job_debts_done",
			"Find Nell in the east lanes")
	var hunt := _job_quest("What Hunts the Hunters", "Help Tamsin Holt hunt the ghoul pack in the north wood.", hob, "job_hunt_done",
			"Join Tamsin in the north wood")
	for job in [vigil, debts, hunt]:
		_connect(asked, &"completed", job, &"start")
	# A job a day: their roads open on a rested morning; back in the evening, it's the inn first
	_gate(_story, "TodaysWork", [], {"requires": ["rested"], "unless": ["jobs_two_done"], "reversible": true,
			"show": [to_vigil, to_debts, to_hunt]})
	_gate(_story, "Evening", [], {"unless": ["rested"], "reversible": true, "time": "dusk"})
	var two := _gate(_story, "TwoJobsDone", ["job_vigil_done", "job_debts_done", "job_hunt_done"],
			{"needed": 2, "requires": ["rested"], "show": [corwin], "hide": [bede, fenn, hob, to_vigil, to_debts, to_hunt],
			"flags": ["jobs_two_done"]})
	for job in [vigil, debts, hunt]:
		_connect(two, &"opened", job, &"abandon")  # the one left over: too late for it now
	_gate(_story, "TheRoadUpTheValley", ["stranger_contract_signed"], {"show": [to_hollow]})
	_save(root, VILLAGE)


func _job_quest(title: String, description: String, giver: NeutralSpawn, flag: String, objective: String) -> Quest:
	var quest := _quest(_story, title, description, false)
	_step(quest, "Talk to %s" % giver.definition.display_name, "talk", giver)
	_step(quest, objective, "flag", flag)
	return quest
