extends SceneTree
## The first campaign's flow (STORY.md, built by tools/story/make_story_maps.gd), as placeholders:
## the prologue's road and farm; Netherby's jobs, nights at the inn, the chandler, the Pit and
## the stranger; and the maps after, each with its quest. Flags stand in for the jobs' fights.

const VILLAGE := "res://scenes/maps/village.tscn"
const STORY := "res://scenes/maps/story/"

var _failures := 0
var support: Script


func _initialize() -> void:
	support = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	await process_frame
	var campaign := Campaign.current
	campaign.flags = {}

	# --- The Broken Road ---
	var map: Node3D = support.call(&"open_map", self, ["maren"], Campaign.FIRST_MAP)
	await process_frame
	await _scenes_done(map)
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var commander: Commander = map.get_node("Commander")
	var maren := registry.unit_of(commander.heroes[0])
	_check("the prologue starts with Maren", maren.definition.display_name == "Maren")
	_check("and Brook", _brook(registry, maren) != null)
	var road: Quest = map.get_node("Story/TheBrokenRoad")
	_check("The Broken Road is under way", road.is_running())
	var axle: NeutralSpawn = map.get_node("Story/TheAxle")
	registry.talk(axle.handle, maren.handle)
	await create_timer(0.5).timeout
	_check("looking at the carriage moves it on", road.current != null and road.current.name == &"Step2")
	await _scenes_done(map)
	# The long way round: the driver's tracks, the pedlar's fire, the farm, a supper
	for place in ["Story/TheTracks", "Story/ThePedlarsFire"]:
		maren.teleport((map.get_node(place) as Node3D).global_position)
		await create_timer(1.0).timeout
		await _scenes_done(map)
	_check("the tracks and the pedlar's fire lead on to the farm", road.current != null and road.current.objective.begins_with("Find shelter"))
	_check("a pedlar on the road, with a little to sell", (map.get_node("Story/PedlarsWares") as Vendor).stock.size() == 2)
	maren.teleport((map.get_node("Story/TheFarm") as Node3D).global_position)
	await create_timer(1.0).timeout
	await _scenes_done(map)
	_check("at the farm, supper first", road.current != null and road.current.objective.contains("supper")
			and not campaign.has_story_flag(&"rested"))
	registry.talk((map.get_node("Story/RootCellar") as NeutralSpawn).handle, maren.handle)
	await create_timer(1.0).timeout
	await _scenes_done(map)
	_check("a night at the farm: morning comes, rested", campaign.has_story_flag(&"rested")
			and campaign.flags.get("time_of_day", {}).get(map.scene_file_path, &"") == &"dawn")
	var honey: Meal = load("res://data/meals/honey_cakes.tres")
	_check("the first supper: its blessing lasts until the next night", maren.buffs().any(func(buff: Dictionary) -> bool:
			return buff.label == honey.display_name))
	var exit: MapExit = map.get_node("Story/ToNetherby")
	_check("and the road to Netherby opens", exit.visible and exit.can_process())

	# --- Netherby ---
	campaign.travel(VILLAGE, "Story/Arrivals/FromRoad")
	map = await _arrive(map)
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	maren = registry.unit_of(commander.heroes[0])
	var party: PartyInventory = map.get_node("Party")
	_check("arrived in Netherby on the road", maren.global_position.distance_to((map.get_node("Story/Arrivals/FromRoad") as Node3D).global_position) < 4.0)
	_check("Brook came along", _brook(registry, maren) != null)
	var stuck := registry.get_children().filter(func(proxy: Node) -> bool:
		return proxy.has_meta(&"animation") and proxy.process_mode == Node.PROCESS_MODE_DISABLED)
	_check("the townsfolk's models aren't switched off (only their animation, off screen)", stuck.is_empty())
	var brann: NeutralSpawn = map.get_node("Villagers/Innkeeper")
	registry.talk(brann.handle, maren.handle)
	await create_timer(0.5).timeout
	var inn: Inn = map.get_node("Story/SleepingBoar")
	_check("talking to Brann offers a bed", is_instance_valid(inn._window))
	if is_instance_valid(inn._window):
		inn._window.close()
	var vigil: Quest = map.get_node("Story/TheNightVigil")
	_check("and three jobs", campaign.has_story_flag(&"jobs_offered") and vigil.is_running())
	var lanes: MapExit = map.get_node("Story/Jobs/ToTheLanes")
	_check("a rested morning: the jobs' roads are open", lanes.visible)

	# A job spends the day: back in the evening, the roads wait for the inn
	campaign.travel(STORY + "vigil.tscn")
	map = await _arrive(map)
	_check("on a job, the day is spent", not campaign.has_story_flag(&"rested"))
	campaign.set_story_flag(&"job_vigil_done")
	campaign.travel(VILLAGE, "Story/Arrivals/FromVigil")
	map = await _arrive(map)
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	maren = registry.unit_of(commander.heroes[0])
	party = map.get_node("Party")
	inn = map.get_node("Story/SleepingBoar")
	lanes = map.get_node("Story/Jobs/ToTheLanes")
	_check("back in the evening: dusk, roads shut", not lanes.visible
			and campaign.flags.get("time_of_day", {}).get(map.scene_file_path, &"") == &"dusk")
	party.gold = 5
	_check("a night needs the gold", not inn.rest(null).is_empty() and party.gold == 5)
	party.gold = 40
	var stew: Meal = load("res://data/meals/barley_stew.tres")
	var regen := maren.stats.value(Stats.Stat.HEALTH_REGEN)
	_check("a night with supper", inn.rest(stew).is_empty() and party.gold == 40 - inn.price - stew.price and Inn.day() == 2)
	_check("the supper's bonus lasts the night", is_equal_approx(maren.stats.value(Stats.Stat.HEALTH_REGEN), regen + 1.5))
	await create_timer(0.5).timeout
	_check("morning: rested, the roads open again", campaign.has_story_flag(&"rested") and lanes.visible)

	# The chandler buys and sells
	var shop: Vendor = map.get_node("Story/ChandlersShop")
	var cap := shop.stock[0]
	party.gold = 200
	var bag_before := party.bag.size()
	_check("buying from the chandler", shop.buy(0).is_empty() and party.gold == 200 - shop.price_of(cap) and party.bag.size() == bag_before + 1)
	var offer := shop.offer_for(party.bag[party.bag.size() - 1])
	var gold_before := party.gold
	_check("and selling back", shop.sell(party.bag.size() - 1).is_empty() and party.gold == gold_before + offer and shop.stock.has(cap))

	# A rumor becomes a quest: the Twin Brands, found out in the valley, joined in the combine grid
	var wat: NeutralSpawn = map.get_node("Story/OldWat")
	var brands: Quest = map.get_node("Story/TheTwinBrands")
	_check("Old Wat's rumor isn't a quest yet", not brands.is_running() and not brands.done)
	registry.talk(wat.handle, maren.handle)
	for i in 600:
		if brands.is_running():
			break
		await process_frame
	_check("heard out, his tale becomes a quest", brands.is_running())
	party.add(load("res://data/items/firebrand.tres"))
	party.add(load("res://data/items/lightbrand.tres"))
	await create_timer(1.5).timeout
	_check("both halves found (any order): on to joining them", brands.current != null and brands.current.item != null
			and brands.current.item.resource_path.ends_with("twin_brands.tres"))
	party.add(load("res://data/items/twin_brands.tres"))
	await create_timer(1.0).timeout
	_check("joined: the Twin Brands' quest is done", brands.done)

	# The Pit: an arena, a round won pays at once; falling there isn't a defeat
	campaign.travel(STORY + "pit.tscn")
	map = await _arrive(map)
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	maren = registry.unit_of(commander.heroes[0])
	party = map.get_node("Party")
	var arena: ArenaChallenge = map.get_node("Story/Arena")
	var question: ConfirmWindow = null
	for node in root.get_children():
		if node is ConfirmWindow:
			question = node
	_check("after the rules, Bram asks: the day's cost", question != null and not arena.running and paused)
	if question != null:
		question.call(&"_answer", true)
	await process_frame
	_check("the Pit's arena runs once you say fight", arena.running and arena.rounds.size() == 6)
	for i in 600:
		if not (arena.get(&"_foes") as Array).is_empty():
			break
		await process_frame
	var foes: Array = (arena.get(&"_foes") as Array).duplicate()
	gold_before = party.gold
	for handle: int in foes:
		registry.apply_damage(handle, 1.0e6, UnitRegistry.NONE, false)
	await create_timer(0.3).timeout
	_check("round one won: paid at once, the next on its way", not foes.is_empty() and arena.rounds_won == 1
			and party.gold == gold_before + arena.rounds[0].prize and arena.number == 2)
	_check("once a day", campaign.has_story_flag(&"pit_today"))
	for i in 900:
		if not (arena.get(&"_foes") as Array).is_empty():
			break
		await process_frame
	for handle in commander.heroes:
		registry.apply_damage(handle, 1.0e6, UnitRegistry.NONE, false)
	await create_timer(3.5).timeout
	var defeated := root.get_children().any(func(node: Node) -> bool: return node is DefeatWindow)
	_check("falling in the Pit: dragged out alive with the winnings, no defeat window", not arena.running and not defeated
			and commander.heroes.all(func(handle: int) -> bool: return registry.is_alive(handle)) and arena.gold == arena.rounds[0].prize)
	_check("and worn out for the day", maren.buffs().any(func(buff: Dictionary) -> bool: return buff.label == "Worn out")
			and campaign.has_story_flag(ArenaChallenge.FATIGUE_FLAG))
	await _scenes_done(map)

	# The second job: the stranger comes the morning after
	campaign.set_story_flag(&"job_hunt_done")
	campaign.set_story_flag(&"rested", false)
	campaign.travel(VILLAGE, "Story/Arrivals/FromRoad")
	map = await _arrive(map)
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	maren = registry.unit_of(commander.heroes[0])
	party = map.get_node("Party")
	inn = map.get_node("Story/SleepingBoar")
	var corwin: NeutralSpawn = map.get_node("Story/Corwin")
	_check("two jobs done, but not before morning", not registry.is_alive(corwin.handle))

	# A save that evening; the stranger's plea cut short by loading it plays again the next morning
	_check("saving the evening", campaign.save_game("story_evening").is_empty())
	party.gold = 20
	inn.rest(null)
	await create_timer(2.5).timeout
	registry.talk(corwin.handle, maren.handle)
	await create_timer(0.5).timeout
	var plea := map.get_node("Story/TheStrangersPleaDoubted") as StoryScene
	_check("his plea starts; no saving in the middle of it", plea.playing and not campaign.save_refusal().is_empty())
	_check("loading in the middle of it", campaign.load_game("story_evening").is_empty())
	map = await _arrive(map)
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	maren = registry.unit_of(commander.heroes[0])
	party = map.get_node("Party")
	inn = map.get_node("Story/SleepingBoar")
	corwin = map.get_node("Story/Corwin")
	_check("back to the evening: unpaused, the plea unheard", not paused and StoryScene.active == 0
			and not campaign.is_opened(map.get_node("Story/TheStrangersPleaDoubted"))
			and not campaign.has_story_flag(&"stranger_contract_signed") and not registry.is_alive(corwin.handle))
	_check("still worn out back in Netherby", maren.buffs().any(func(buff: Dictionary) -> bool: return buff.label == "Worn out"))
	party.gold = 20
	inn.rest(null)
	await create_timer(2.5).timeout
	_check("a night's sleep: worn out no more", not maren.buffs().any(func(buff: Dictionary) -> bool: return buff.label == "Worn out")
			and not campaign.has_story_flag(ArenaChallenge.FATIGUE_FLAG))
	var bede: NeutralSpawn = map.get_node("Story/Jobs/AcolyteBede")
	var debts: Quest = map.get_node("Story/DebtsoftheLiving")
	var work: Quest = map.get_node("Story/WorkforCoin")
	_check("the morning after, the stranger waits at the inn", registry.is_alive(corwin.handle))
	_check("the jobs close: givers gone", not registry.is_alive(bede.handle))
	_check("the third job is over, undone", debts.done and not campaign.has_story_flag(&"job_debts_done"))
	_check("Work for Coin moves on to the stranger", work.current != null and work.current.objective.contains("waiting"))
	_check("the Pit opens again with the new day", not campaign.has_story_flag(&"pit_today")
			and (map.get_node("Story/ToThePit") as MapExit).visible)
	registry.talk(corwin.handle, maren.handle)
	await create_timer(0.5).timeout
	_check("with Tamsin's job done, she doubts him", (map.get_node("Story/TheStrangersPleaDoubted") as StoryScene).playing)
	await _scenes_done(map)
	_check("the contract is signed", campaign.has_story_flag(&"stranger_contract_signed"))
	_check("and the road up the valley opens", (map.get_node("Story/ToBriarsHollow") as MapExit).visible)

	# --- The maps after: each starts its quest ---
	for entry: Array in [["debts", "DebtsoftheLiving"], ["hunt", "WhatHuntstheHunters"], ["hollow", "BriarsHollow"],
			["lodge", "TheGleanersLodge"], ["finale", "TheRingofWater"]]:
		campaign.travel(STORY + entry[0] + ".tscn")
		map = await _arrive(map)
		await _scenes_done(map)
		var quest: Quest = map.get_node_or_null("Story/" + entry[1])
		var levels := {"debts": 2, "hunt": 3, "hollow": 5, "lodge": 6, "finale": 7}
		_check("%s: its monsters at level %d" % [entry[0], levels[entry[0]]],
				(map.get_node("UnitRegistry") as UnitRegistry).monster_level == levels[entry[0]])
		_check("%s: its quest is under way" % entry[0], quest != null and (quest.is_running() or quest.done))
		_check("%s: nothing of Netherby's (its givers, quests, inn) came along with the template" % entry[0],
				map.get_node_or_null("Story/Jobs") == null and map.get_node_or_null("Story/SleepingBoar") == null
				and map.get_node_or_null("Story2") == null)
		if entry[0] == "lodge":
			registry = map.get_node("UnitRegistry")
			await create_timer(1.0).timeout
			var risen := 0
			for handle in registry.handles(UnitRegistry.Kind.NPC):
				if registry.definition_of(handle).display_name == "Risen Nell":
					risen += 1
			_check("the lodge: Nell, the one left behind, comes back Risen", campaign.has_story_flag(&"lodge_trap_sprung")
					and risen == 1)

	# Scenes that overlap (a step completing starts two): the last one over unpauses, whichever ends first
	var first := StoryScene.new()
	var second := StoryScene.new()
	for scene: StoryScene in [first, second]:
		scene.once = false
		scene.lines = PackedStringArray(["Maren: One.", "Maren: Two."])
		map.add_child(scene)
	first.play()
	second.play()
	_check("two scenes at once: paused", paused and StoryScene.active == 2)
	first.skip()
	_check("the first over: still paused, for the second", paused and StoryScene.active == 1)
	second.skip()
	_check("the last over: the game runs again", not paused and StoryScene.active == 0)
	first.free()
	second.free()

	# The whole party falls: the defeat window offers the last save
	registry = map.get_node("UnitRegistry")
	commander = map.get_node("Commander")
	for handle in commander.heroes:
		registry.apply_damage(handle, 1.0e6, UnitRegistry.NONE, false)
	await create_timer(3.0).timeout
	var defeat: DefeatWindow = null
	for node in root.get_children():
		if node is DefeatWindow:
			defeat = node
	_check("the party falls: the defeat window, paused, with the last save", defeat != null and paused
			and defeat.find_children("*", "Button", true, false).size() == 2)
	if defeat != null:
		defeat.close()
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _arrive(from: Node) -> Node3D:
	await support.call(&"scene_changed", self, from)
	await create_timer(0.5).timeout
	await _scenes_done(current_scene)
	return current_scene


func _brook(registry: UnitRegistry, maren: Unit) -> Unit:
	for unit in registry.unit_nodes():
		if unit.bound and unit.summoner == maren:
			return unit
	return null


## Waits while any StoryScene in the map plays (they move on by themselves, faster at test speed).
func _scenes_done(map: Node) -> void:
	for i in 600:
		var playing := map.find_children("*", "StoryScene", true, false).any(func(s: Node) -> bool: return (s as StoryScene).playing)
		if not playing:
			return
		await process_frame


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
