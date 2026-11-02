extends RefCounted
## Shared by the test drivers in this folder (tests/run_tests.sh runs them).

## The bag the item tests were written for (the first starting kit), independent of
## whatever data/items/starting_kit.tres holds now.
const TEST_KIT: Array[String] = ["militia_sword", "war_mace", "hunting_bow", "leather_cap", "circlet_of_nobility",
		"iron_pauldrons", "mantle_of_intelligence", "chainmail", "leather_bracers", "gauntlets_of_ogre_strength",
		"gloves_of_haste", "boots_of_speed", "slippers_of_agility", "periapt_of_vitality", "pendant_of_willpower",
		"ring_of_protection", "ring_of_protection", "ring_of_regeneration", "lightbrand", "firebrand"]


## Runs the game SPEED times faster (default 16): time is scaled, and the physics ticks are
## too, so every physics step still covers 1/60 s of game time and units move as in play.
## Also puts the test's saves in Campaign.TEST_SAVE_DIR, away from the player's.
## Timers (create_timer) count game time; wait on process frames for "the next frame".
static func speed_up() -> void:
	Campaign.save_dir = Campaign.TEST_SAVE_DIR  # tests delete their saves: never the player's
	var speed := float(OS.get_environment("SPEED")) if OS.has_environment("SPEED") else 16.0
	Engine.time_scale = speed
	Engine.physics_ticks_per_second = roundi(60.0 * speed)
	Engine.max_physics_steps_per_frame = maxi(8, roundi(speed * 1.5))


## Opens `path` as the current scene with this party (unit file names in data/units) and
## TEST_KIT in the bag. Maps without their own starting_party would spawn main.gd's
## DEFAULT_PARTY (the Rogue alone).
static func open_map(tree: SceneTree, party: Array, path := "res://scenes/main.tscn") -> Node3D:
	var scene: Node3D = load(path).instantiate()
	var definitions: Array[UnitDefinition] = []
	for unit_name: String in party:
		definitions.append(load("res://data/units/%s.tres" % unit_name))
	scene.set("starting_party", definitions)
	var bag := scene.get_node_or_null(^"Party") as PartyInventory
	if bag != null:
		var kit := ItemCatalog.new()
		for id in TEST_KIT:
			kit.items.append(load("res://data/items/%s.tres" % id))
		bag.starting_items = kit
	tree.root.add_child(scene)
	tree.current_scene = scene
	return scene


## Waits until the current scene isn't `from` any more, at most `limit` real seconds: a map
## exit or Campaign.travel loads the next map on a thread, which takes real time however fast
## the game runs, so a timer in game time can run out first at 16x. `from` is untyped: it may
## be freed already.
static func scene_changed(tree: SceneTree, from: Variant, limit := 10.0) -> void:
	var deadline := Time.get_ticks_msec() + roundi(limit * 1000.0)
	while ((is_instance_valid(from) and tree.current_scene == from) or tree.current_scene == null) \
			and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	await tree.process_frame  # its _ready ran, the party arrived


## Where a test writes logs, screenshots and scratch files (OUTPUT, default tests/output).
static func output_dir() -> String:
	return OS.get_environment("OUTPUT") if OS.has_environment("OUTPUT") \
			else ProjectSettings.globalize_path("res://tests/output")
