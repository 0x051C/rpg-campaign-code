extends SceneTree
## Monster levels and champions (DIRECTION.md 2): a map's level makes its monsters tougher, a champion
## gets its modifiers' numbers and does what they say (chill, life steal, mana burn, a burst where it
## falls), quests still count it as its kind, and it survives a save as itself.

const SKELETON := preload("res://data/units/skeleton_warrior.tres")
const MODIFIERS := "res://data/modifiers/"

var _failures := 0


func _initialize() -> void:
	var support: Script = load("res://tests/framework/support.gd")
	support.call(&"speed_up")
	var map: Node3D = support.call(&"open_map", self, ["maren"], "res://scenes/maps/story_template.tscn")
	await create_timer(0.5).timeout
	var registry: UnitRegistry = map.get_node("UnitRegistry")
	var commander: Commander = map.get_node("Commander")
	var maren := registry.unit_of(commander.heroes[0])
	maren.teleport(Vector3(0, 0, 0))
	var spawner := CreepSpawner.new()
	spawner.team = UnitRegistry.CREATURE_TEAM
	spawner.active = false
	map.add_child(spawner)
	spawner.global_position = Vector3(30, 0, 30)

	# The map's level
	registry.monster_level = 1
	var common := registry.spawn_npc(SKELETON, spawner.team, Vector3(30, 0, 30), spawner)
	_check("level 1, no modifiers: the monster as authored", registry.definition_of(common) == SKELETON)
	registry.monster_level = 5
	var leveled := registry.spawn_npc(SKELETON, spawner.team, Vector3(32, 0, 30), spawner)
	var five := registry.definition_of(leveled)
	_check("level 5: more health, damage, armor and bounty", five.monster_level == 5
			and is_equal_approx(five.max_health, SKELETON.max_health * 1.6) and is_equal_approx(five.attack_damage, SKELETON.attack_damage * 1.4)
			and is_equal_approx(five.armor, SKELETON.armor + 1.0) and five.bounty_experience > SKELETON.bounty_experience)
	var again := registry.spawn_npc(SKELETON, spawner.team, Vector3(34, 0, 30), spawner)
	_check("monsters alike share one leveled copy", registry.definition_of(again) == five)
	_check("and still count as their kind (kill quests)", five.is_a(SKELETON) and not SKELETON.is_a(five))

	# A champion
	var fire: MonsterModifier = load(MODIFIERS + "fire_enchanted.tres")
	var vampiric: MonsterModifier = load(MODIFIERS + "vampiric.tres")
	var cold: MonsterModifier = load(MODIFIERS + "cold_enchanted.tres")
	var burn: MonsterModifier = load(MODIFIERS + "mana_burn.tres")
	var strong: MonsterModifier = load(MODIFIERS + "extra_strong.tres")
	_check("seven modifiers in the pool", MonsterModifier.pool().size() == 7)
	spawner.modifiers = [strong]
	var brute := registry.definition_of(registry.spawn_npc(SKELETON, spawner.team, Vector3(36, 0, 30), spawner))
	_check("a champion: its modifiers' numbers on top of the level's", brute.is_champion()
			and is_equal_approx(brute.attack_damage, SKELETON.attack_damage * 1.4 * UnitDefinition.CHAMPION_DAMAGE * 1.5)
			and is_equal_approx(brute.max_health, SKELETON.max_health * 1.6 * UnitDefinition.CHAMPION_HEALTH))
	spawner.modifiers = [vampiric, cold, burn]
	var champion := registry.spawn_npc(SKELETON, spawner.team, Vector3(2, 0, 0), spawner)
	registry.set_health(champion, 10.0)
	maren.mana = 100.0
	registry.call(&"_champion_hit", maren.handle, champion, 30.0)
	_check("Vampiric: its hit heals it", is_equal_approx(registry.health_of(champion), 10.0 + 30.0 * vampiric.life_steal))
	_check("Cold Enchanted: its hit chills", registry.slow_of(maren.handle) > 0.0)
	_check("Mana Burn: its hit burns mana", is_equal_approx(maren.mana, 100.0 - burn.mana_burn))

	# A champion's definition survives a save as itself
	var saved := SaveCodec.decode_resource(SaveCodec.encode_resource(registry.definition_of(champion))) as UnitDefinition
	_check("saved and loaded: level, modifiers, its kind", saved.monster_level == 5 and saved.modifiers.size() == 3
			and saved.modifiers.has(vampiric) and saved.is_a(SKELETON))

	# Fire Enchanted goes off where it fell (kills near a hero share experience: health is read after)
	registry.apply_damage(champion, 1.0e6, UnitRegistry.NONE, false)
	spawner.modifiers = [fire]
	var torch := registry.spawn_npc(SKELETON, spawner.team, Vector3(1.5, 0, 0), spawner)
	registry.apply_damage(torch, 1.0e6, UnitRegistry.NONE, false)
	var health := registry.health_of(maren.handle)
	_check("not at once: the ground is marked first", registry.get(&"_bursts").size() == 1)
	await create_timer(fire.death_delay + 0.5).timeout
	_check("Fire Enchanted: a moment later, the burst hurts who stayed", registry.health_of(maren.handle) <= health - fire.death_damage + 2.0)

	# Camps send packs: all champions alike, or none
	var camp := NeutralCamp.new()
	camp.creatures = [SKELETON, SKELETON, SKELETON]
	camp.camp_size = 3
	camp.champion_chance = 1.0
	camp.spawn_on_start = false
	camp.respawn_time = 0.0
	map.add_child(camp)
	camp.global_position = Vector3(6, 0, 6)  # in sight: the fog drops inspections of what the player can't see
	await process_frame
	camp.spawn_group()
	var pack := registry.npcs_of(camp)
	var shared := pack.size() == 3
	for handle in pack:
		shared = shared and registry.definition_of(handle).is_champion() and registry.definition_of(handle) == registry.definition_of(pack[0])
	_check("a champion camp is one pack: the same modifiers on all", shared)

	# Knowing your enemy: inspecting a champion shows its bar and a card saying what it does
	var panel: EnemyPanel = map.get_node("HUD/EnemyPanel")
	commander.info_selection.assign([pack[0]])
	await process_frame
	var card := EnemyPanel.describe(registry, pack[0])
	var named := true
	for modifier in registry.definition_of(pack[0]).modifiers:
		named = named and card.contains(modifier.display_name) and card.contains(modifier.description)
	_check("inspected: the enemy bar and its card, every modifier explained", panel.visible and panel.target == pack[0] and named
			and card.contains("Attack") and card.contains("Armor"))
	commander.info_selection.clear()
	await process_frame
	_check("nothing inspected or hovered: no bar", not panel.visible or panel.target != pack[0])
	print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)


func _check(what: String, ok: bool) -> void:
	print("%s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
