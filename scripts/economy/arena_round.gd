class_name ArenaRound
extends Resource

## One round of the arena (ArenaChallenge): who comes through the gate, what they carry, and what
## Bram pays when they're all down. Rounds teach: give a round's foes a modifier by name, and its
## hint says what to do about it; the enemy card (click one) says the rest.

@export var title := "Round"
## Bram's call as the round starts: what to watch for.
@export_multiline var hint := ""
@export var creatures: Array[UnitDefinition] = []
## Levels above the map's (UnitRegistry.monster_level).
@export var level_bonus := 0
## Every foe of the round has these.
@export var modifiers: Array[MonsterModifier] = []
## And each may roll more, as a champion.
@export_range(0.0, 1.0) var champion_chance := 0.0
## A computer hero with real spells (HeroBrain) joins them, at the party's level.
@export var hero: UnitDefinition
## Gold for winning it.
@export var prize := 10
