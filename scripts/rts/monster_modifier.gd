class_name MonsterModifier
extends Resource

## A champion's trait, Diablo II's monster modifiers (DIRECTION.md 2): Extra Strong, Stone Skin,
## Fire Enchanted... A champion (UnitDefinition.leveled) carries one to three; its name shows in
## blue with them listed under it, and clicking it says what each does.
##
## All in numbers, no script per trait: multipliers on the monster's own, what its hits do, and
## what happens where it dies. The pool champions roll from is every file in data/modifiers.

const POOL_DIR := "res://data/modifiers/"

@export var display_name := "Modifier"
@export_multiline var description := ""
@export var color := Color(0.45, 0.65, 1.0)

@export_group("Numbers")
@export var health := 1.0  ## times its health
@export var damage := 1.0  ## times its attack damage
@export var armor := 0.0  ## added armor
@export var move_speed := 1.0  ## times its speed
@export var attack_speed := 1.0  ## times its attack rate (its swings and cooldown shorten)

@export_group("Its hits")
## Chill what it hits: this share of movement taken (attacks slow by half as much), for `chill_time`.
@export_range(0.0, 1.0) var chill := 0.0
@export var chill_time := 3.0
## Heals it by this share of the damage its hits do.
@export_range(0.0, 1.0) var life_steal := 0.0
## Mana its hits burn from a hero.
@export var mana_burn := 0.0

@export_group("Its death")
## Where it falls, a blast after `death_delay` seconds: damage to its enemies within `death_radius`.
@export var death_damage := 0.0
@export var death_radius := 3.0
@export var death_delay := 0.6
@export var death_element := &"fire"  ## the impact sound and color (Sounds' elements)

static var _pool: Array[MonsterModifier] = []


func acts_on_hit() -> bool:
	return chill > 0.0 or life_steal > 0.0 or mana_burn > 0.0


## Every modifier in data/modifiers.
static func pool() -> Array[MonsterModifier]:
	if _pool.is_empty():
		for file in ResourceLoader.list_directory(POOL_DIR):
			if file.ends_with(".tres"):
				var modifier := load(POOL_DIR + file) as MonsterModifier
				if modifier != null:
					_pool.append(modifier)
	return _pool


## `count` different modifiers at random.
static func roll(count: int) -> Array[MonsterModifier]:
	var picked: Array[MonsterModifier] = pool().duplicate()
	picked.shuffle()
	return picked.slice(0, mini(count, picked.size()))
