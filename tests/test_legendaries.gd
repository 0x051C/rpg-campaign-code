extends SceneTree
## Legendary items (DIRECTION.md 1, Diablo 3's orange): a fixed name, slot and power with a couple of
## random affixes on top; bosses drop them more often than champions; each power does its thing when
## worn (the Twin Brands' echo, the Ashen Harrow's burst, the Gleaner's Sickle's lifesong, the
## Widow's Coil's surge, the Rime Sigil's chill, the Vigil Lantern's shield); they survive a save.

const LEGENDARY := "res://data/items/legendary/"

var _failures := 0
var registry: UnitRegistry
var spawner: CreepSpawner
var skeleton: UnitDefinition = load("res://data/units/skeleton_warrior.tres")


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")

	# Rolling one
	var rolled := LootRoller.random_legendary(6)
	_check("a legendary: orange, its power, its own name, two rolls on top", rolled != null
			and rolled.rarity == ItemDefinition.Rarity.LEGENDARY and rolled.power != null and rolled.rolled.size() == 2
			and rolled.display_name == rolled.base_item.display_name and rolled.item_level == 6)
	var saved := SaveCodec.decode_resource(SaveCodec.encode_resource(rolled)) as ItemDefinition
	_check("saved and loaded, it keeps its power and rolls", saved.power == rolled.power and saved.rolled == rolled.rolled)
	var boss: UnitDefinition = load("res://data/units/story/ghoul_mother.tres")
	var from_boss := 0
	var from_common := 0
	for i in 300:
		from_boss += LootRoller.drops_for(boss).items.filter(func(item: ItemDefinition) -> bool:
				return item.rarity == ItemDefinition.Rarity.LEGENDARY).size()
		from_common += LootRoller.drops_for(skeleton).items.filter(func(item: ItemDefinition) -> bool:
				return item.rarity == ItemDefinition.Rarity.LEGENDARY).size()
	_check("bosses drop legendaries now and then; common monsters never", from_boss > 60 and from_boss < 160 and from_common == 0)

	var map: Node3D = support.call(&"open_map", self, ["knight", "maren"], "res://scenes/maps/story_template.tscn")
	await create_timer(0.5).timeout
	registry = map.get_node("UnitRegistry")
	var commander: Commander = map.get_node("Commander")
	var knight := registry.unit_of(commander.heroes[0])
	var maren := registry.unit_of(commander.heroes[1])
	knight.teleport(Vector3(0, 0, 0))
	maren.teleport(Vector3(-10, 0, 10))
	spawner = CreepSpawner.new()
	spawner.team = 2
	spawner.active = false
	map.add_child(spawner)

	# The Twin Brands' echo: a second strike and a slow, then not again until its cooldown
	_wear(knight, load("res://data/items/twin_brands.tres"))
	var victim := _spawn(Vector3(0, 0, -2))
	await process_frame
	var before := registry.health_of(victim)
	knight.call(&"_attack_landed", victim, Callable(), 40.0)
	var first := before - registry.health_of(victim)
	_check("the Twin Brands echo: a second strike, and a slow", first > 0.0 and registry.slow_of(victim) > 0.5)
	before = registry.health_of(victim)
	knight.call(&"_attack_landed", victim, Callable(), 40.0)
	_check("not again until the echo is back", is_equal_approx(registry.health_of(victim), before))
	registry.kill(victim)

	# The Ashen Harrow: what you kill bursts
	_wear(knight, load(LEGENDARY + "ashen_harrow.tres"))
	var doomed := _spawn(Vector3(3, 0, -3))
	var neighbor := _spawn(Vector3(4, 0, -4))
	await process_frame
	var neighbor_before := registry.health_of(neighbor)
	registry.apply_damage(doomed, 1.0e6, knight.handle, false)
	_check("the Ashen Harrow: a kill bursts into flame around it", registry.health_of(neighbor) < neighbor_before)
	registry.kill(neighbor)

	# The Gleaner's Sickle: blows heal
	_wear(knight, load(LEGENDARY + "gleaners_sickle.tres"))
	var target := _spawn(Vector3(-3, 0, -3))
	await process_frame
	registry.set_health(knight.handle, 100.0)
	knight.call(&"_attack_landed", target, Callable(), 100.0)
	_check("the Gleaner's Sickle: a blow heals its wielder", registry.health_of(knight.handle) > 100.0)

	# The Widow's Coil: a spell quickens attacks
	_wear(maren, load(LEGENDARY + "widows_coil.tres"))
	var speed := maren.stats.value(Stats.Stat.ATTACK_SPEED)
	var blizzard: AbilityDefinition = maren.definition.abilities[0]
	var cast := _spell(maren, blizzard, Vector3(-10, 0, 0))
	for power in maren.worn_powers():
		power.on_cast(maren, blizzard, cast)
	_check("the Widow's Coil: a spell quickens her attacks", maren.stats.value(Stats.Stat.ATTACK_SPEED) > speed)

	# The Rime Sigil: a spell's area chills
	_wear(maren, load(LEGENDARY + "rime_sigil.tres"))
	var chilled := _spawn(Vector3(-10, 0, 1))
	await process_frame
	for power in maren.worn_powers():
		power.on_cast(maren, blizzard, _spell(maren, blizzard, Vector3(-10, 0, 0)))
	_check("the Rime Sigil: enemies in a spell's area are chilled", registry.slow_of(chilled) > 0.0)

	# The Vigil Lantern: Holy Light shields
	_wear(knight, load(LEGENDARY + "vigil_lantern.tres"))
	var light: AbilityDefinition = knight.definition.abilities[0]
	var on_maren := _spell(knight, light, maren.global_position)
	on_maren.target = maren.handle
	for power in knight.worn_powers():
		power.on_cast(knight, light, on_maren)
	_check("the Vigil Lantern: Holy Light shields its friend", float(maren.get(&"_shield_time")) > 0.0)

	# Kit legendaries change a hero's own spells
	_wear(knight, load(LEGENDARY + "brand_of_the_vigil.tres"))
	var wrath: AbilityDefinition = knight.definition.abilities[3]
	wrath.cast(_spell(knight, wrath, knight.global_position))
	var struck := _spawn(Vector3(0, 0, -2))
	var close := _spawn(Vector3(1.5, 0, -3))
	await process_frame
	knight.call(&"_attack_landed", struck, Callable(), 30.0)
	var burning: bool = registry.get(&"_effects").get(close, {}).has(&"vigil_fire")
	_check("Brand of the Vigil: Wrath's cleave sets them burning", burning)
	for handle in [struck, close]:
		registry.kill(handle)

	_wear(maren, load(LEGENDARY + "tidecallers_pearl.tres"))
	var pearl: AbilityDefinition = maren.definition.abilities[3]
	var pearl_cast := _spell(maren, pearl, Vector3(-10, 0, -6))
	pearl.cast(pearl_cast)
	for power in maren.worn_powers():
		power.on_cast(maren, pearl, pearl_cast)
	var placed: Node = pearl_cast.data.get("pearl")
	_check("Tidecaller's Pearl: the Pearl lasts longer and pulls harder", is_instance_valid(placed)
			and float(placed.get(&"duration")) > pearl.value(&"duration", 1) and float(placed.get(&"pull")) > 1.0)
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _wear(hero: Unit, item: ItemDefinition) -> void:
	hero.equipment[Equipment.place_for(hero.equipment, item)] = item
	hero.recalculate_stats()


func _spawn(at: Vector3) -> int:
	return registry.spawn_npc(skeleton, 2, at, spawner)


func _spell(caster: Unit, ability: AbilityDefinition, point: Vector3) -> SpellCast:
	var spell := SpellCast.new()
	spell.caster = caster
	spell.ability = ability
	spell.level = 1
	spell.registry = caster.registry
	spell.point = point
	return spell


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
