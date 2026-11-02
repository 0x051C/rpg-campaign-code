class_name UnitDefinition
extends Resource

## Static data shared by every unit of one type (noh: the unit entity definition,
## src/hon_shared/i_unitdefinition.h; DotaCraft: npc_units_custom / npc_heroes).
## Distances are meters, times are seconds.
##
## A hero class also has core stats and class passives (STATS_AND_ITEMS.md); its health,
## mana, armor and damage below are then the base the stats are added to.

const UNDEAD_PASSIVE := preload("res://data/passives/undead.tres")

@export var display_name := "Unit"
## A character prefab from scenes/characters: edit it once and every map follows.
@export var model: PackedScene
@export var undead := false  ## the Undead faction: holy healing burns it instead (UNDEAD_PASSIVE)
@export var formation_rank := 0  ## DotaCraft FormationRank: 0 front line ... 5 ancients
@export var siege := false  ## noh combat type "Siege": ignores aggro pulls
@export var bounty_experience := 25.0  ## DotaCraft BountyXP

@export_group("Stats")
@export var max_health := 100.0
@export var max_mana := 0.0
@export var mana_regen := 0.0  ## per second
@export var armor := 0.0  ## flat damage taken off every hit (StarCraft)
@export var armor_type := Stats.Armor.MEDIUM
@export var move_speed := 4.5
@export var turn_rate := 12.0  ## radians per second
@export var aggro_range := 8.0
## How far its team sees around it (FogOfWar; DotaCraft VisionDaytimeRange: 1400 units, heroes 1800).
@export var sight_range := 1400.0 / RTSCamera.NOH_UNITS_PER_METER
## Sees over walls and high ground (noh ClearVision), e.g. flyers.
@export var clear_vision := false

@export_group("Hero")
@export var abilities: Array[AbilityDefinition] = []
## Small passives, one effect each; the class's main stat comes as one of them.
@export var passives: Array[ClassPassive] = []
## Strength, Dexterity, Intelligence, Willpower at level 1; empty for units without core stats.
@export var base_stats := PackedFloat32Array()
## What each core stat gains per level, in the same order.
@export var stat_gains := PackedFloat32Array()

@export_group("Resource")
## Off: mana starts empty and must be built up (the Rogue's combo).
@export var mana_starts_full := true
## Mana gained per attack that hits and per parried attack, before Combo power.
@export var mana_per_hit := 0.0
@export var mana_per_parry := 0.0

@export_group("Attack")
@export var attack_damage := 10.0
## null deals plain damage; a hero's weapon replaces it.
@export var attack_type: AttackType
@export var attack_range := 1.2  ## edge to edge
@export var attack_cooldown := 1.2
@export var attack_point := 0.35  ## delay from swing start until the hit lands
@export var attack_backswing := 0.35
@export var attack_animation: StringName = &"general/Throw"
@export var projectile_speed := 0.0  ## 0 for melee
@export var projectile_color := Color.WHITE
## What its attacks do when they land, besides damage (Brook's chill). Heroes and summons only.
@export var attack_effect: AttackEffect

@export_group("Body")
@export var radius := 0.5
@export var height := 2.4

@export_group("Loot")
## Named items this kind may drop (LootRoller): the recipe parts players farm, Dota's way.
@export var named_drops: Array[ItemDefinition] = []
@export_range(0.0, 1.0) var named_drop_chance := 0.0

@export_group("Level")
## A monster's level (DIRECTION.md 2), set on the copy leveled() makes; 0: as authored.
@export var monster_level := 0
## A champion's modifiers (leveled()); its name shows in blue with them.
@export var modifiers: Array[MonsterModifier] = []
## What leveled() made this from (quests count kills of the base: is_a()).
@export var base: UnitDefinition

## Per monster level above the first: health, attack damage and bounty grow by these shares, armor by
## this much (placeholder numbers, DIRECTION.md 2).
const HEALTH_PER_LEVEL := 0.15
const DAMAGE_PER_LEVEL := 0.10
const ARMOR_PER_LEVEL := 0.25
const BOUNTY_PER_LEVEL := 0.2
## A champion, before its modifiers: tougher, and worth more.
const CHAMPION_HEALTH := 1.5
const CHAMPION_DAMAGE := 1.15
const CHAMPION_BOUNTY := 2.5

static var _leveled: Dictionary[String, UnitDefinition] = {}  ## "<base id> <level> <modifier ids>" -> copy


func is_ranged() -> bool:
	return projectile_speed > 0.0


## This one, or a leveled copy of `other` (a quest that wants skeletons counts level 5 champions too).
func is_a(other: UnitDefinition) -> bool:
	return self == other or (base != null and base.is_a(other))


func is_champion() -> bool:
	return not modifiers.is_empty()


## A copy at monster `level` with `champion_modifiers` (none: a common monster), made once and shared
## by every monster alike. Level 1 without modifiers is this one itself. Leveling a leveled copy
## starts again from its base.
func leveled(level: int, champion_modifiers: Array[MonsterModifier] = []) -> UnitDefinition:
	if base != null:
		return base.leveled(level, champion_modifiers)
	level = maxi(level, 1)
	if level == 1 and champion_modifiers.is_empty():
		return self
	var ids := PackedStringArray()
	for modifier in champion_modifiers:
		ids.append(modifier.resource_path.get_file() if not modifier.resource_path.is_empty() else str(modifier.get_instance_id()))
	var key := "%s %d %s" % [resource_path if not resource_path.is_empty() else str(get_instance_id()), level, ",".join(ids)]
	if _leveled.has(key):
		return _leveled[key]
	var copy := duplicate() as UnitDefinition
	copy.base = self
	copy.monster_level = level
	copy.modifiers = champion_modifiers.duplicate()
	var steps := level - 1
	var health_scale := 1.0 + HEALTH_PER_LEVEL * steps
	var damage_scale := 1.0 + DAMAGE_PER_LEVEL * steps
	var bounty_scale := 1.0 + BOUNTY_PER_LEVEL * steps
	copy.armor += ARMOR_PER_LEVEL * steps
	if not champion_modifiers.is_empty():
		health_scale *= CHAMPION_HEALTH
		damage_scale *= CHAMPION_DAMAGE
		bounty_scale *= CHAMPION_BOUNTY
	var attack_rate := 1.0
	for modifier in champion_modifiers:
		health_scale *= modifier.health
		damage_scale *= modifier.damage
		copy.armor += modifier.armor
		copy.move_speed *= modifier.move_speed
		attack_rate *= modifier.attack_speed
	copy.max_health *= health_scale
	copy.attack_damage *= damage_scale
	copy.bounty_experience *= bounty_scale
	copy.attack_cooldown /= attack_rate
	copy.attack_point /= attack_rate
	copy.attack_backswing /= attack_rate
	_leveled[key] = copy
	return copy


## The class's passives, then the faction's.
func all_passives() -> Array[ClassPassive]:
	var all: Array[ClassPassive] = passives.duplicate()
	if undead:
		all.append(UNDEAD_PASSIVE)
	return all
