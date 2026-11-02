class_name EnemyPanel
extends Control

## Knowing your enemy (DIRECTION.md 3). Hovering one shows Diablo's bar at the top of the screen: its
## name (blue for a champion), level, health, and its modifiers in their colors. Clicking it
## (inspecting: Commander.info_selection) opens a card under the bar with what it does: its attack,
## armor and speed, what each modifier means, and its spells, so the arena's foes can be learned.
##
## The map root adds one to the HUD (main.gd); nothing to place by hand.

const WIDTH := 420.0  ## the bar
const CARD_WIDTH := 380.0
const BAR_HEIGHT := 12.0
const CHAMPION_COLOR := Color(0.45, 0.65, 1.0)
const NAME_COLOR := Color(0.95, 0.9, 0.85)
const HEALTH_COLOR := Color(0.75, 0.15, 0.12)
const DIM := Color(0.65, 0.65, 0.65)

var commander: Commander
var target := UnitRegistry.NONE  ## what it shows now

var _bar := Control.new()
var _card := PanelContainer.new()
var _text := RichTextLabel.new()
var _card_of := UnitRegistry.NONE  ## the unit the card was written for


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The bar at the top in the middle, Diablo's place; the card at the left edge, off the fight
	_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_bar.offset_left = -WIDTH * 0.5
	_bar.offset_right = WIDTH * 0.5
	_bar.offset_top = 8.0
	_bar.offset_bottom = 64.0
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.draw.connect(_draw_bar)
	add_child(_bar)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.05, 0.07, 0.88)
	style.border_color = Color(0.45, 0.38, 0.25)
	style.set_border_width_all(1)
	style.set_content_margin_all(10.0)
	_card.add_theme_stylebox_override(&"panel", style)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.position = Vector2(16.0, 96.0)
	_card.custom_minimum_size.x = CARD_WIDTH
	_card.size.x = CARD_WIDTH
	add_child(_card)
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.custom_minimum_size.x = CARD_WIDTH - 20.0
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.add_theme_font_size_override(&"normal_font_size", 14)
	_text.add_theme_font_size_override(&"bold_font_size", 15)
	_card.add_child(_text)
	_card.visible = false


func _process(_delta: float) -> void:
	if commander == null:
		return
	var registry := commander.registry
	var inspected := commander.info_selection[0] if commander.info_selection.size() == 1 else UnitRegistry.NONE
	target = commander.hover if _shows(commander.hover) else (inspected if _shows(inspected) else UnitRegistry.NONE)
	visible = target != UnitRegistry.NONE
	if not visible:
		return
	_card.visible = target == inspected
	if _card.visible and _card_of != target:
		_card_of = target
		_text.text = "[b][color=#%s]%s[/color][/b]\n%s" % [(CHAMPION_COLOR if registry.definition_of(target).is_champion() else NAME_COLOR).to_html(false),
				registry.definition_of(target).display_name, describe(registry, target)]
		_card.reset_size()  # shrink to the new text
	elif not _card.visible:
		_card_of = UnitRegistry.NONE
	_bar.queue_redraw()


## Enemies of the player, alive: not the party, not the villagers.
func _shows(handle: int) -> bool:
	var registry := commander.registry
	return handle != UnitRegistry.NONE and registry.is_alive(handle) \
			and UnitRegistry.are_enemies(registry.team_of(handle), registry.player_team)


func _draw_bar() -> void:
	var registry := commander.registry
	if target == UnitRegistry.NONE or not registry.is_alive(target):
		return
	var definition := registry.definition_of(target)
	var font := get_theme_default_font()
	var name_color := CHAMPION_COLOR if definition.is_champion() else NAME_COLOR
	var title := definition.display_name
	var unit := registry.unit_of(target)
	var level := unit.level if unit != null else maxi(definition.monster_level, 1)
	_bar.draw_string_outline(font, Vector2(0, 16), title, HORIZONTAL_ALIGNMENT_CENTER, WIDTH, 18, 4, Color.BLACK)
	_bar.draw_string(font, Vector2(0, 16), title, HORIZONTAL_ALIGNMENT_CENTER, WIDTH, 18, name_color)
	var rect := Rect2(0, 22, WIDTH, BAR_HEIGHT)
	var share := registry.health_of(target) / maxf(registry.max_health_of(target), 1.0)
	_bar.draw_rect(rect.grow(1.0), Color(0, 0, 0, 0.85))
	_bar.draw_rect(Rect2(rect.position, Vector2(rect.size.x * clampf(share, 0.0, 1.0), rect.size.y)), HEALTH_COLOR)
	var level_text := "Level %d" % level
	_bar.draw_string_outline(font, rect.position + Vector2(4, 10), level_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, 3, Color.BLACK)
	_bar.draw_string(font, rect.position + Vector2(4, 10), level_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)
	# The modifiers under the bar, each in its color; else a hint
	var x := 0.0
	var parts: Array[Array] = []
	for modifier in definition.modifiers:
		parts.append([modifier.display_name, modifier.color])
	if definition.undead:
		parts.append(["Undead", Color(0.7, 0.85, 0.6)])
	var widths: Array[float] = []
	var total := 0.0
	for part in parts:
		var w := font.get_string_size(part[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		widths.append(w)
		total += w + (14.0 if total > 0.0 else 0.0)
	x = (WIDTH - total) * 0.5
	for i in parts.size():
		_bar.draw_string_outline(font, Vector2(x, 50), parts[i][0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 3, Color.BLACK)
		_bar.draw_string(font, Vector2(x, 50), parts[i][0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, parts[i][1])
		x += widths[i] + 14.0
	if not _card.visible and parts.is_empty():
		_bar.draw_string(font, Vector2(0, 50), "Click it to learn what it does", HORIZONTAL_ALIGNMENT_CENTER, WIDTH, 11, DIM)


## The card: what the unit `handle` does, as BBCode.
static func describe(registry: UnitRegistry, handle: int) -> String:
	var definition := registry.definition_of(handle)
	var unit := registry.unit_of(handle)
	var lines: Array[String] = []
	var attack := definition.attack_damage if unit == null else registry.attack_damage(handle, unit.stats.value(Stats.Stat.ATTACK_DAMAGE))
	var how := "ranged, %s m" % AbilityDefinition.format_number(snappedf(definition.attack_range, 0.1)) if definition.is_ranged() else "melee"
	var attack_type := definition.attack_type.display_name if definition.attack_type != null else "Normal"
	lines.append("[b]Attack[/b]  %d %s damage, %s, every %ss" % [roundi(attack), attack_type, how,
			AbilityDefinition.format_number(snappedf(definition.attack_cooldown, 0.05))])
	if definition.attack_type != null and not definition.attack_type.bonuses.is_empty():
		lines.append("[color=#a0a0a0]%s[/color]" % definition.attack_type.describe())
	var armor := unit.stats.value(Stats.Stat.ARMOR) if unit != null else definition.armor
	lines.append("[b]Armor[/b]  %s (%s)   [b]Speed[/b]  %s" % [AbilityDefinition.format_number(snappedf(armor, 0.1)),
			Stats.ARMOR_NAMES[definition.armor_type], AbilityDefinition.format_number(snappedf(definition.move_speed, 0.1))])
	if definition.undead:
		lines.append("[color=#b4d89a]Undead[/color]: holy light burns it instead of healing.")
	for modifier in definition.modifiers:
		lines.append("[color=#%s][b]%s[/b][/color]: %s" % [modifier.color.to_html(false), modifier.display_name, modifier.description])
	var abilities: Array[AbilityDefinition] = definition.abilities
	for slot in abilities.size():
		var ability := abilities[slot]
		if ability == null:
			continue
		var level := unit.ability_level(slot) if unit != null else 1
		if unit != null and level <= 0:
			continue
		var facts: Array[String] = []
		if ability.cooldown_at(maxi(level, 1)) > 0.0:
			facts.append("every %ss" % AbilityDefinition.format_number(ability.cooldown_at(maxi(level, 1))))
		if ability.radius > 0.0:
			facts.append("%s m around" % AbilityDefinition.format_number(snappedf(ability.radius, 0.1)))
		lines.append("[color=#8cb4ff][b]%s[/b][/color]%s: %s" % [ability.display_name,
				" (%s)" % ", ".join(facts) if not facts.is_empty() else "", ability.describe(maxi(level, 1))])
	return "\n".join(lines)
