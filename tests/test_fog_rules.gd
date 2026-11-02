extends SceneTree
## Fog of war rules on the main map, waves off:
## 1. a far enemy is hidden and can't be picked; attacking reveals it for aggression_sight_time
## 2. an attack order whose target vanishes into the fog walks to the last seen spot, then ends
## 3. a creep doesn't target a hero it can't see behind a rock, though in aggro range

var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var scene: Node3D = support.call(&"open_map", self, ["knight", "ranger", "mage"])  # the party these checks expect
	var camera: RTSCamera = scene.get_node("RTSCamera")
	camera.edge_scroll = false
	var registry: UnitRegistry = scene.get_node("UnitRegistry")
	var commander: Commander = scene.get_node("Commander")
	var fog: FogOfWar = scene.get_node("FogOfWar")
	var waves := scene.get_node("CreepWaves")
	var north: CreepSpawner = scene.get_node("NorthSpawner")
	await process_frame
	waves.set("_next_wave_time", 999.0)
	await create_timer(1.0).timeout
	var knight := registry.unit_of(commander.heroes[0])
	var mage_def: UnitDefinition = load("res://data/units/skeleton_mage.tres")
	var minion_def: UnitDefinition = load("res://data/units/skeleton_minion.tres")

	# 1. Hidden far enemy, revealed by attacking
	var far := _stand(registry, registry.spawn_npc(mage_def, 2, Vector3(0, 0, -40), north))
	await create_timer(0.6).timeout
	_check("far enemy hidden", not registry.player_sees(far))
	var screen := camera.camera.unproject_position(registry.aim_point(far))
	_check("far enemy not pickable", registry.pick(camera.camera, screen) != far)
	registry.deliver_attack(far, knight.handle, 0.0, mage_def)
	_check("attacker revealed at once", registry.player_sees(far))
	await create_timer(1.5).timeout
	_check("attacker still revealed after 1.5 s", registry.player_sees(far))
	await create_timer(2.5).timeout
	_check("attacker hidden again after 4 s", not registry.player_sees(far))
	registry.kill(far)

	# 2. Attack order on a target that goes into the fog
	var near := _stand(registry, registry.spawn_npc(minion_def, 2, Vector3(7, 0, 30), north))
	registry.set_invulnerable(near, true)
	await create_timer(0.6).timeout
	_check("near enemy seen", registry.player_sees(near))
	knight.order_attack(near, Unit.Queue.NONE)
	await create_timer(0.3).timeout
	var seen_at := registry.position_of(near)
	registry.place(near, Vector3(-60, 0, -60))  # gone: far into the fog
	await create_timer(0.8).timeout
	_check("target hidden after it left", not registry.player_sees(near))
	_check("attack order kept while walking to the last seen spot", not knight.orders.is_empty())
	await create_timer(4.0).timeout
	_check("attack order dropped at the last seen spot", knight.orders.is_empty())
	print("   knight stopped at ", knight.global_position.snappedf(0.1), ", target last seen at ", seen_at.snappedf(0.1))
	registry.kill(near)

	# 3. Creep in aggro range, hero hidden behind a rock
	var rock: MapProp = scene.get_node("NavigationRegion3D/Rock5")
	var footprint := rock.get_footprint()
	var reach := 0.0
	var center := Vector2(rock.global_position.x, rock.global_position.z)
	for point in footprint:
		reach = maxf(reach, point.distance_to(center))
	print("   rock top %.2f, reach %.2f" % [rock.get_top(), reach])
	var creep_at := Vector3(center.x, 0, center.y - reach - 1.2)
	var hero_at := Vector3(center.x, 0, center.y + reach + 1.2)
	for handle in commander.heroes:
		registry.unit_of(handle).teleport(Vector3(40, 0, 40))  # far from everything
	knight.teleport(hero_at)
	knight.order_hold(Unit.Queue.NONE)
	var creep := _stand(registry, registry.spawn_npc(minion_def, 2, creep_at, north))
	var definition := registry.definition_of(creep)
	print("   creep-hero distance %.1f, aggro range %.1f" % [creep_at.distance_to(hero_at), definition.aggro_range])
	await create_timer(1.5).timeout
	_check("creep can't see the hero behind the rock", not registry.can_see(2, knight.handle))
	_check("creep picks no target", registry.best_target(creep) == UnitRegistry.NONE)
	knight.teleport(Vector3(creep_at.x + 3.0, 0, creep_at.z))  # step around the rock
	knight.order_hold(Unit.Queue.NONE)
	await create_timer(1.5).timeout
	_check("creep sees the hero in the open", registry.can_see(2, knight.handle))
	_check("creep picks the hero", registry.best_target(creep) == knight.handle)

	print("FAILURES: %d" % _failures)
	quit()


## Keeps a creep where it was put: rows without a lane stand still.
func _stand(registry: UnitRegistry, handle: int) -> int:
	registry.hold_position(handle)
	return handle


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
