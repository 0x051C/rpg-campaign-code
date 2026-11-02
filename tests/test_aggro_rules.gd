extends SceneTree
## Who the enemies go for, and blows that can't reach: a summon (Brook) near its master draws the enemies
## first and keeps them while she casts (UnitRegistry core: threat_summon, a roused camp keeps its targets);
## a melee blow landing past its attack range and a buffer misses (UnitRegistry.MELEE_REACH_BUFFER, 150 HoN units).

var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var map: Node3D = support.call(&"open_map", self, ["maren"], "res://scenes/maps/story_template.tscn")
	await create_timer(1.0).timeout
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var console := DevConsole.current
	console.run("skip; god")  # nobody dies while we watch who they go for
	var maren: Unit = (map.get_node("Party") as PartyInventory).heroes()[0]
	var brook: Unit = null
	for unit in registry.unit_nodes():
		if unit.is_summon() and unit.summoner == maren:
			brook = unit
	_check("Brook is with Maren", brook != null)
	maren.teleport(Vector3(0, 0, 4))
	brook.teleport(Vector3(1.5, 0, 2))
	await create_timer(0.3).timeout

	# A camp (the creatures' team, standing at home), nearer to Maren than to Brook
	var commander: Commander = map.get_node("Commander")
	commander.trace_position = Vector3(-3, 0, 1)
	console.run("spawn skeleton_minion 4 3")
	await process_frame
	var pack := _enemies(registry)
	var nearer_maren := pack.filter(func(h: int) -> bool:
		return registry.position_of(h).distance_to(maren.global_position) < registry.position_of(h).distance_to(brook.global_position))
	_check("most of the camp stands nearer Maren", nearer_maren.size() >= 2)
	registry.apply_damage(pack[0], 1.0, brook.handle, false, false)  # Brook starts it
	await create_timer(2.0).timeout
	_check("the pack goes for Brook, not Maren", pack.size() == 4 and pack.all(func(h: int) -> bool: return registry.target_of(h) == brook.handle))

	# Maren hurts them (a spell's worth): they stay on Brook
	for handle in pack:
		registry.apply_damage(handle, 5.0, maren.handle, false, false)
	await create_timer(1.5).timeout
	_check("and stay on Brook when Maren's spells land", pack.all(func(h: int) -> bool:
			return not registry.is_alive(h) or registry.target_of(h) == brook.handle))
	console.run("killall")
	console.run("god")
	await create_timer(0.3).timeout

	# A melee blow out of reach misses; one in reach lands
	var skeleton: UnitDefinition = load("res://data/units/skeleton_minion.tres")
	commander.trace_position = Vector3(12, 0, -12)
	console.run("spawn skeleton_minion 1")
	await process_frame
	var swinger := _enemies(registry)[0]
	var before := registry.health_of(maren.handle)
	var evaded := []
	registry.attack_evaded.connect(func(victim: int) -> void: evaded.append(victim))
	var far_blow := registry.deliver_attack(swinger, maren.handle, 30.0, skeleton)
	_check("a melee blow from %.1f m misses" % registry.edge_distance(swinger, maren.handle),
			not far_blow and is_equal_approx(registry.health_of(maren.handle), before) and evaded.has(maren.handle))
	maren.teleport(registry.position_of(swinger) + Vector3(1.2, 0, 0))
	await create_timer(0.2).timeout
	before = registry.health_of(maren.handle)
	var near_blow := false
	for i in 10:  # evasion may dodge one
		near_blow = registry.deliver_attack(swinger, maren.handle, 30.0, skeleton)
		if near_blow:
			break
	_check("one within reach lands", near_blow and registry.health_of(maren.handle) < before)
	# Just past the buffer misses, just inside it lands
	var reach := skeleton.attack_range + UnitRegistry.MELEE_REACH_BUFFER
	var swinger_at := registry.position_of(swinger)
	var gap := func(edge: float) -> Vector3:  # where Maren stands for an edge distance of `edge`
		return swinger_at + Vector3(edge + registry.radius_of(swinger) + registry.radius_of(maren.handle), 0, 0)
	maren.teleport(gap.call(reach + 0.4))
	await create_timer(0.2).timeout
	_check("just past range + buffer (%.1f m): misses" % registry.edge_distance(swinger, maren.handle),
			not registry.deliver_attack(swinger, maren.handle, 30.0, skeleton))
	maren.teleport(gap.call(reach - 0.4))
	await create_timer(0.2).timeout
	var inside := false
	for i in 10:
		inside = registry.deliver_attack(swinger, maren.handle, 30.0, skeleton)
		if inside:
			break
	_check("just inside it (%.1f m): lands" % registry.edge_distance(swinger, maren.handle), inside)
	var ranged: UnitDefinition = load("res://data/units/skeleton_mage.tres")
	maren.teleport(Vector3(-12, 0, 12))
	await create_timer(0.2).timeout
	_check("ranged attacks aren't held to it", ranged.is_ranged() and registry.deliver_attack(swinger, maren.handle, 10.0, ranged))
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _enemies(registry: UnitRegistry) -> Array[int]:
	var found: Array[int] = []
	for handle in registry.handles():
		if registry.is_alive(handle) and UnitRegistry.are_enemies(registry.team_of(handle), registry.player_team):
			found.append(handle)
	return found


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
