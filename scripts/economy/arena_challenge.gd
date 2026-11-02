class_name ArenaChallenge
extends Node

## Bram Toller's Pit as an arena (DIRECTION.md 4; it replaced the last-hitting challenge, which these
## controls don't suit). Rounds of foes come through `gate`, champions with modifiers and computer
## heroes with real spells, harder each time; click one to learn what it does (EnemyPanel). Win a
## round and its prize is paid at once; between rounds there's a breather, and the way out stays
## open: leave and keep what you won. Fall, and Bram's men drag the party out alive with its winnings
## (no defeat screen here). A day's visit runs the rounds once.
##
## It costs the day (your call, DIRECTION.md 4): before the first round it asks, and win or lose the
## party leaves worn out (`fatigue`) until its next night at an inn, so a day at the Pit is a day not
## spent on a job. Win every round and Bram adds a Pit-forged item: a rare, a level above the Pit's.

signal round_started(number: int, round: ArenaRound)
signal round_won(number: int, prize: int)
## Over: every round won, the party fell, or it left. How many rounds were won, and the gold.
signal finished(rounds_won: int, gold: int)

const GROUP := &"spares_party"  ## while one of these runs, the party falling isn't a defeat (main.gd)
const BANNER := Color(1.0, 0.85, 0.45)

@export var rounds: Array[ArenaRound] = []
## Where the foes come in: its team is theirs, its lane leads them (and its heroes) to the party.
@export var gate: CreepSpawner
## Seconds between rounds; before the first, a short count.
@export var break_time := 10.0
@export var first_delay := 3.0
## Where the dragged-out party wakes up.
@export var recovery_spot: Node3D
## Asked before the first round: the day's cost. Empty: no question.
@export_multiline var cost_question := "Win or lose, you'll come out of the Pit worn out: slower blows and slower healing until you sleep at an inn. A day in the Pit is a day not spent on a job."

const FATIGUE := &"fatigue"
const TOKEN_FROM_ROUND := 4  ## rounds from this one on pay a smith's token too (Blacksmith)
const FATIGUE_FLAG := &"pit_fatigue"  ## set when the rounds begin, cleared by a night at an inn
const FATIGUE_BONUSES: Dictionary[Stats.Stat, float] = {Stats.Stat.ATTACK_SPEED: -15.0, Stats.Stat.HEALTH_REGEN: -1.0,
		Stats.Stat.MANA_REGEN: -0.5}

var number := 0  ## the round under way or next, from 1; 0 before it starts
var rounds_won := 0
var gold := 0
var running := false

var _registry: UnitRegistry
var _foes: Array[int] = []
var _wait := -1.0  ## counting down to the next round; -1 while one is fought
var _layer: CanvasLayer
var _banner: Label
var _hint: Label


func _ready() -> void:
	Simulation.join(self, Simulation.Order.TRIGGERS)


## Starts the rounds (connectable to any signal: the rules' StoryScene `finished`).
func start(_a: Variant = null, _b: Variant = null) -> void:
	if running or rounds.is_empty() or gate == null:
		return
	if not cost_question.is_empty():
		var question := ConfirmWindow.ask(get_tree(), "Into the Pit?", cost_question, "Fight", "Not today")
		question.answered.connect(func(yes: bool) -> void:
			if yes:
				begin())
		return
	begin()


## Starts the rounds, without asking (the question was answered, or there's none). From here the day is
## spent: leaving early still leaves the party worn out (FATIGUE_FLAG, main.gd).
func begin() -> void:
	if running or rounds.is_empty() or gate == null:
		return
	Campaign.current.set_story_flag(FATIGUE_FLAG)
	_registry = get_tree().get_first_node_in_group(UnitRegistry.GROUP) as UnitRegistry
	if _registry == null:
		return
	running = true
	add_to_group(GROUP)
	number = 1
	rounds_won = 0
	gold = 0
	_foes.clear()
	_wait = first_delay
	if not _registry.unit_died.is_connected(_on_died):
		_registry.unit_died.connect(_on_died)
	_show_banner()
	_announce("Round 1: %s" % rounds[0].title, "Get ready.")


func _exit_tree() -> void:
	if running:  # left through the gate mid-way: what was won is kept
		running = false
		finished.emit(rounds_won, gold)


func _simulate(delta: float) -> void:
	if not running or _wait < 0.0:
		return
	_wait -= delta
	if _wait <= 0.0:
		_wait = -1.0
		_send(number)


## Sends round `which` (1-based) through the gate.
func _send(which: int) -> void:
	var round := rounds[which - 1]
	gate.level_bonus = round.level_bonus
	gate.modifiers = round.modifiers.duplicate()
	gate.champion_chance = round.champion_chance
	_foes.clear()
	for i in round.creatures.size():
		if round.creatures[i] == null:
			continue
		var handle := _registry.spawn_npc(round.creatures[i], gate.team, gate.formation_position(i), gate)
		if handle != UnitRegistry.NONE:
			_foes.append(handle)
	if round.hero != null:
		var waves := get_tree().get_first_node_in_group(CreepWaves.GROUP) as CreepWaves
		if waves != null:
			gate.hero = round.hero
			var hero := waves.spawn_hero(gate, gate.formation_position(round.creatures.size()))
			if hero != null:
				_foes.append(hero.handle)
	_announce("Round %d: %s" % [which, round.title], round.hint)
	round_started.emit(which, round)


func _on_died(handle: int, _killer: int) -> void:
	if not running:
		return
	if _foes.has(handle):
		_foes.erase(handle)
		if _foes.is_empty() and _wait < 0.0:
			_won()
	elif _party_fell(handle):
		_spared()


func _won() -> void:
	var round := rounds[number - 1]
	rounds_won += 1
	gold += round.prize
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	var token := number >= TOKEN_FROM_ROUND
	if party != null:
		party.add_gold(round.prize)
		if token:
			party.tokens += 1  # the later rounds pay a smith's token too
	Sounds.play(&"coin")
	round_won.emit(number, round.prize)
	if number >= rounds.size():
		_announce("The Pit is yours", "All %d rounds. %d gold." % [rounds.size(), gold])
		_end()
		return
	number += 1
	_wait = break_time
	_announce("Round %d won: +%d gold%s" % [number - 1, round.prize, ", and a smith's token" if token else ""],
			"Next: %s, in %d seconds. The way out is open." % [rounds[number - 1].title, int(break_time)])


## Whether every hero is down, `dying` counted as down already (died is told before the body falls).
func _party_fell(dying: int) -> bool:
	var commander := _commander()
	if commander == null or not commander.heroes.has(dying):
		return false
	for handle in commander.heroes:
		if handle != dying and _registry.is_alive(handle):
			return false
	return true


## The party fell: Bram's men pull it out alive, and the foes go back behind the gate.
func _spared() -> void:
	_announce("Dragged out of the Pit", "Bram's men pull you clear. You keep the %d gold you won." % gold)
	for handle in _foes:
		if UnitRegistry.kind_of(handle) == UnitRegistry.Kind.NPC:
			_registry.despawn(handle)
		else:
			_registry.kill(handle)
	_foes.clear()
	_end()
	await get_tree().create_timer(2.0).timeout
	var commander := _commander()
	if commander == null:
		return
	for i in commander.heroes.size():
		var unit := _registry.unit_of(commander.heroes[i])
		if unit == null:
			continue
		unit.revive(0.25)
		if recovery_spot != null:
			unit.teleport(recovery_spot.global_position + Vector3(i * 1.5, 0, 0))
	_tire_party()  # getting up clears what they carried; the day's fatigue stays


func _end() -> void:
	running = false
	_wait = -1.0
	remove_from_group(GROUP)
	_tire_party()
	if rounds_won >= rounds.size():
		_forge_prize()
	finished.emit(rounds_won, gold)


## Worn out until the next night at an inn (Inn.rest takes it off).
func _tire_party() -> void:
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	if party != null:
		tire(party.heroes())


## The Pit's fatigue on `heroes` (again, after a map change: main.gd).
static func tire(heroes: Array) -> void:
	for hero: Unit in heroes:
		hero.add_buff(FATIGUE, "Worn out", "Wo", Color(0.55, 0.5, 0.45),
				"A day in the Pit: slower blows and slower healing until you sleep at an inn.", Inn.MEAL_TIME, FATIGUE_BONUSES)


## Every round won: a Pit-forged rare, a level above the Pit's monsters, into the bag.
func _forge_prize() -> void:
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP) as PartyInventory
	var bases := LootRoller.catalog().loot_bases
	if party == null or bases.is_empty():
		return
	var prize := LootRoller.roll(bases.pick_random(), _registry.monster_level + 2, ItemDefinition.Rarity.RARE)
	prize.display_name = "Pit-forged " + prize.display_name
	party.add(prize)
	_announce("Pit-forged", "Bram tosses you %s: \"Earned it.\"" % prize.display_name)


func _commander() -> Commander:
	var party := get_tree().get_first_node_in_group(PartyInventory.GROUP)
	return party.get(&"commander") as Commander if party != null else null


func _show_banner() -> void:
	if _layer != null:
		return
	_layer = CanvasLayer.new()
	_layer.layer = 20
	add_child(_layer)
	_banner = _label(26, BANNER, 74.0)
	_hint = _label(16, Color(0.92, 0.9, 0.85), 108.0)


func _label(font_size: int, color: Color, top: float) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	label.add_theme_constant_override(&"outline_size", 6)
	label.anchor_left = 0.5
	label.anchor_right = 0.5
	label.offset_left = -360.0
	label.offset_right = 360.0
	label.offset_top = top
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(label)
	return label


func _announce(banner: String, hint: String) -> void:
	if _banner == null:
		return
	_banner.text = banner
	_hint.text = hint
