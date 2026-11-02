extends SceneTree
## Items: hover shows name and ring, smart-click sends the nearest hero, walking over does
## nothing. Gold: walking over picks it up. OUT=<prefix> for screenshots.

var _out := OS.get_environment("OUT")
var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var campaign := Campaign.current
	campaign.flags = {}
	support.call(&"open_map", self, ["knight", "ranger", "mage"])  # the party these checks expect
	await create_timer(1.5).timeout
	var map := current_scene
	map.get_node("CreepWaves").set("_next_wave_time", 999.0)
	var camera: RTSCamera = map.get_node("RTSCamera")
	camera.edge_scroll = false
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var commander: Commander = map.get_node("Commander")
	var party: PartyInventory = map.get_node("Party")
	var heroes: Array[Unit] = []
	for handle in commander.heroes:
		heroes.append(registry.unit_of(handle))
	var sword: ItemPickup = map.get_node("Props/DroppedSword1")
	var bag_before := party.bag.size()

	# Walking over an item does nothing
	heroes[0].teleport(sword.ground_spot())
	await create_timer(0.8).timeout
	_check("walking over the sword doesn't pick it up", is_instance_valid(sword) and party.bag.size() == bag_before)
	heroes[0].teleport(sword.ground_spot() + Vector3(-6, 0, 3))

	# Hover: name and ring
	camera.center_on(sword.global_position)
	camera.distance = 16.0
	await create_timer(0.6).timeout
	var view := camera.camera
	var screen := view.unproject_position(sword.global_position + Vector3.UP * 0.2)
	_motion(screen)
	await create_timer(0.2).timeout
	for i in 3:  # the hover is marked each frame; the ring follows on the item's next frame (0.2 s at 16x can be under one)
		await process_frame
	_check("hovering the sword: commander knows it", commander.hover_item == sword)
	_check("its ring shows", sword._ring != null and sword._ring.visible)
	await _shot("hover")

	# Smart-click with the whole party selected: only the nearest hero goes
	commander.control_selection.assign(commander.heroes)
	var nearest := heroes[0]
	for hero in heroes:
		if hero.global_position.distance_to(sword.ground_spot()) < nearest.global_position.distance_to(sword.ground_spot()):
			nearest = hero
	_click(screen, MOUSE_BUTTON_RIGHT)
	for frame in 10:  # the click is handled a frame or two later (later still after a screenshot)
		await process_frame
		if heroes.any(func(h: Unit) -> bool: return not h.orders.is_empty()):
			break
	var with_order := heroes.filter(func(h: Unit) -> bool: return not h.orders.is_empty() and h.orders[0].type == UnitOrder.Type.PICKUP)
	_check("one hero (the nearest) walks over to pick it up", with_order.size() == 1 and with_order[0] == nearest)
	await create_timer(4.0).timeout
	_check("the sword is in the bag", party.bag.size() == bag_before + 1 and not is_instance_valid(sword))

	# Gold: walking over is enough
	var pile: ItemPickup = map.get_node("Props/GoldPile1")
	heroes[1].teleport(pile.ground_spot())
	await create_timer(0.6).timeout
	_check("walking over gold picks it up (+25)", party.gold == 25 and not is_instance_valid(pile))

	# Too heavy: the item stays, the hero says why
	var book: ItemPickup = map.get_node("Props/DroppedSpellbook1")
	party.capacity = party.carried_weight()
	heroes[2].teleport(book.ground_spot() + Vector3(1, 0, 0))
	heroes[2].order_pickup(book, Unit.Queue.NONE)
	await create_timer(1.0).timeout
	_check("too heavy: it stays on the ground, the order ends", is_instance_valid(book) and heroes[2].orders.is_empty()
			and commander.error_text.begins_with("Too heavy"))
	party.capacity = 90.0

	# Dropped gold and items survive a save and load; the purse too
	ItemPickup.drop_gold(map, 12, Vector3(10, 0, 30))
	_check("save", campaign.save_game("pickup").is_empty())
	campaign.load_game("pickup")
	await campaign.loaded
	await process_frame
	map = current_scene
	party = map.get_node("Party")
	var dropped := get_nodes_in_group(ItemPickup.RUNTIME_GROUP)
	_check("the purse is restored (25 gold)", party.gold == 25)
	_check("dropped gold lies where it was", dropped.size() == 1 and (dropped[0] as ItemPickup).gold == 12)
	_check("picked-up sword and gold stay gone", map.get_node_or_null("Props/DroppedSword1") == null and map.get_node_or_null("Props/GoldPile1") == null)
	print("FAILURES: %d" % _failures)
	quit()


func _motion(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	Input.parse_input_event(motion)


func _click(at: Vector2, button: MouseButton) -> void:
	_motion(at)
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.position = at
		event.global_position = at
		event.pressed = pressed
		Input.parse_input_event(event)


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("%s_%s.png" % [_out, shot_name])
