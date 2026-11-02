class_name SpellPanel
extends PanelContainer

## The spell part of noh's control panel (CGameInterfaceManager::UpdateActiveInventory):
## the active unit's name, level, experience, health and mana, then one SpellSlot per
## ability with a tooltip carrying noh's description fields (name, level, text, mana,
## cooldown, range, target type).
##
## Below the spells sit the item bar's two rows (STATS_AND_ITEMS.md): an "i" icon for the
## class's passives (they're listed in the character window, which a click opens), the attack
## type of the worn weapon and the running buffs (round, hover only), then the abilities of
## worn items.

enum Hover { NONE, SPELL, PASSIVE, ATTACK_TYPE, BUFF }

const HOTKEYS: Array[String] = ["Q", "W", "E", "R"]
const ITEM_HOTKEYS: Array[String] = ["D", "F", "G", "X", "B"]
const ITEM_BAR_SIZE := 36.0
const BUFF_RING := Color(1.0, 0.85, 0.35)  ## buffs are ringed in gold, passives in grey
const PASSIVE_SIZE := 30.0
const INFO_COLOR := Color(0.35, 0.45, 0.7)
const MAX_BUFFS := 4
const HEALTH_COLOR := Color(0.3, 0.85, 0.35)
const MANA_COLOR := Color(0.35, 0.55, 1.0)
const XP_COLOR := Color(0.85, 0.7, 0.25)
const ACTION_NAMES: Dictionary[AbilityDefinition.Action, String] = {
	AbilityDefinition.Action.PASSIVE: "Passive",
	AbilityDefinition.Action.NO_TARGET: "No target",
	AbilityDefinition.Action.TARGET_UNIT: "Target unit",
	AbilityDefinition.Action.TARGET_POINT: "Target area",
	AbilityDefinition.Action.TARGET_UNIT_OR_POINT: "Target unit or area",
	AbilityDefinition.Action.ATTACK: "Attack (right-click: autocast)",
}

@export var commander: Commander
@export var tooltip: PanelContainer

var _status := Control.new()
var _slots: Array[SpellSlot] = []
var _info_icon := PassiveIcon.new(PASSIVE_SIZE)
var _attack_icon := PassiveIcon.new(PASSIVE_SIZE)
var _buff_icons: Array[PassiveIcon] = []
var _hover := Hover.NONE
var _hovered := -1  ## the hovered SpellSlot's slot, or passive's index
var _tooltip_text: RichTextLabel


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 6)
	add_child(column)

	_status.custom_minimum_size = Vector2(0, 46)
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.draw.connect(_draw_status)
	column.add_child(_status)

	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	column.add_child(row)
	for i in HOTKEYS.size():
		row.add_child(_add_slot(i, HOTKEYS[i], SpellSlot.SIZE.x))

	var passive_row := HBoxContainer.new()
	passive_row.add_theme_constant_override(&"separation", 4)
	column.add_child(passive_row)
	_info_icon.show_icon("i", INFO_COLOR)
	_watch_hover(_info_icon, Hover.PASSIVE, 0)
	_info_icon.pressed.connect(func() -> void:
		var window := get_tree().get_first_node_in_group(InventoryWindow.GROUP) as InventoryWindow
		if window != null:
			window.toggle())
	passive_row.add_child(_info_icon)
	_watch_hover(_attack_icon, Hover.ATTACK_TYPE, 0)
	passive_row.add_child(_attack_icon)
	for i in MAX_BUFFS:
		var icon := PassiveIcon.new(PASSIVE_SIZE)
		icon.ring_color = BUFF_RING
		_watch_hover(icon, Hover.BUFF, i)
		passive_row.add_child(icon)
		_buff_icons.append(icon)

	var item_row := HBoxContainer.new()
	item_row.add_theme_constant_override(&"separation", 4)
	column.add_child(item_row)
	for i in ITEM_HOTKEYS.size():
		item_row.add_child(_add_slot(Unit.HERO_ABILITY_SLOTS + i, ITEM_HOTKEYS[i], ITEM_BAR_SIZE))

	_tooltip_text = RichTextLabel.new()
	_tooltip_text.bbcode_enabled = true
	_tooltip_text.fit_content = true
	_tooltip_text.scroll_active = false
	_tooltip_text.custom_minimum_size = Vector2(300, 0)
	_tooltip_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tooltip.add_child(_tooltip_text)
	tooltip.visible = false


func _watch_hover(icon: Control, kind: Hover, index: int) -> void:
	icon.mouse_entered.connect(func() -> void:
		_hover = kind
		_hovered = index)
	icon.mouse_exited.connect(func() -> void:
		if _hover == kind and _hovered == index:
			_hover = Hover.NONE)


func _add_slot(index: int, hotkey: String, side: float) -> SpellSlot:
	var slot := SpellSlot.new(side)
	slot.slot = index
	slot.hotkey = hotkey
	slot.activated.connect(commander.activate_ability)
	slot.autocast_toggled.connect(commander.toggle_autocast)
	slot.learn_pressed.connect(commander.learn_ability)
	slot.mouse_entered.connect(func() -> void:
		_hover = Hover.SPELL
		_hovered = index)
	slot.mouse_exited.connect(func() -> void:
		if _hover == Hover.SPELL and _hovered == index:
			_hover = Hover.NONE)
	_slots.append(slot)
	return slot


func _process(_delta: float) -> void:
	var unit := commander.get_caster()
	visible = unit != null
	if unit == null:
		tooltip.visible = false
		return
	for slot in _slots:
		slot.unit = unit
		slot.targeting = commander.active_slot == slot.slot
		if slot.slot < Unit.HERO_ABILITY_SLOTS:
			slot.visible = not unit.definition.abilities.is_empty()
	_info_icon.visible = not unit.definition.all_passives().is_empty()
	var buffs := unit.buffs()
	for i in _buff_icons.size():
		_buff_icons[i].visible = i < buffs.size()
		if i < buffs.size():
			_buff_icons[i].show_icon(buffs[i].glyph, buffs[i].color, buffs[i].get("count", 0))
	var weapon := unit.equipment[Equipment.WEAPON]
	_attack_icon.visible = weapon != null and weapon.attack_type != null  # shows once a weapon is worn
	if _attack_icon.visible:
		_attack_icon.show_icon(weapon.attack_type.icon_glyph, weapon.attack_type.icon_color)
	_status.queue_redraw()
	_update_tooltip(unit)
	# Above the panel, which grows with its rows
	tooltip.offset_bottom = global_position.y - get_viewport_rect().size.y - 8.0
	tooltip.offset_top = tooltip.offset_bottom


func _draw_status() -> void:
	var unit := commander.get_caster()
	if unit == null:
		return
	var font := get_theme_default_font()
	var width := _status.size.x
	var title := unit.definition.display_name
	if not unit.is_summon():
		title += "   Level %d" % unit.level
		if unit.skill_points > 0:
			title += "   +%d" % unit.skill_points
	_status.draw_string(font, Vector2(0, 13), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)

	var registry := commander.registry
	var health := registry.health_of(unit.handle)
	var max_health := registry.max_health_of(unit.handle)
	_bar(Rect2(0, 18, width, 10), health / max_health, HEALTH_COLOR, "%d / %d" % [ceili(health), ceili(max_health)])
	if unit.bound:
		pass  # a bound companion (Brook): no time limit, no mana to show
	elif unit.is_summon():
		_bar(Rect2(0, 31, width, 10), unit.lifetime_left / unit.lifetime, Color(0.8, 0.8, 0.8), "%ds" % ceili(unit.lifetime_left))
	else:
		_bar(Rect2(0, 31, width, 10), unit.mana / maxf(unit.max_mana, 1.0), MANA_COLOR, "%d / %d" % [floori(unit.mana), ceili(unit.max_mana)])
		_status.draw_rect(Rect2(0, 43, width * unit.experience_progress(), 3), XP_COLOR)


func _bar(rect: Rect2, fraction: float, color: Color, label: String) -> void:
	_status.draw_rect(rect, Color(0, 0, 0, 0.7))
	_status.draw_rect(Rect2(rect.position, Vector2(rect.size.x * clampf(fraction, 0.0, 1.0), rect.size.y)), color)
	var font := get_theme_default_font()
	var text_width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
	_status.draw_string(font, rect.position + Vector2((rect.size.x - text_width) * 0.5, 9), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color.WHITE)


func _update_tooltip(unit: Unit) -> void:
	match _hover:
		Hover.SPELL:
			if unit.ability_at(_hovered) == null:
				tooltip.visible = false
				return
			_tooltip_text.text = _spell_tooltip(unit, _hovered)
		Hover.PASSIVE:
			var names: Array[String] = []
			for passive in unit.definition.all_passives():
				names.append(passive.display_name)
			_tooltip_text.text = ("[b]Passives[/b]   [color=#a0a0a0]%s[/color]\n%s\n[color=#80d080]Click, or press I: the " +
					"character window shows what each does and the stats they feed.[/color]") % [unit.definition.display_name,
					", ".join(names)]
		Hover.BUFF:
			var buffs := unit.buffs()
			if _hovered >= buffs.size():
				tooltip.visible = false
				return
			var buff := buffs[_hovered]
			_tooltip_text.text = "[b]%s[/b]   [color=#a0a0a0]%.1fs left[/color]\n%s" % [buff.label, buff.time, buff.description]
		Hover.ATTACK_TYPE:
			var weapon := unit.equipment[Equipment.WEAPON]
			_tooltip_text.text = attack_type_tooltip(weapon.attack_type, weapon.display_name)
		_:
			tooltip.visible = false
			return
	tooltip.visible = true


func _spell_tooltip(unit: Unit, slot: int) -> String:
	var ability := unit.ability_at(slot)
	var level := unit.ability_level(slot)
	var shown := maxi(level, 1)
	var from_item := slot >= Unit.HERO_ABILITY_SLOTS
	var hotkey := ITEM_HOTKEYS[slot - Unit.HERO_ABILITY_SLOTS] if from_item else HOTKEYS[slot]
	var lines: Array[String] = []
	var heading := "[b]%s[/b]" % ability.display_name
	if not from_item:
		heading += "   Level %d/%d" % [level, ability.max_level]
	if not ability.is_passive():
		heading += "   [color=#ffd860][%s][/color]" % hotkey
	lines.append(heading)
	if from_item:
		lines.append("[color=#a0a0a0]From %s[/color]" % unit.equipment[unit.item_ability_equipment(slot)].display_name)
	lines.append(ability.describe(shown))
	var facts: Array[String] = []
	if ability.mana_cost_at(shown) > 0.0:
		facts.append("[color=#8cb4ff]Mana %d[/color]" % roundi(unit.mana_cost(slot)))
	if ability.cooldown_at(shown) > 0.0:
		facts.append("Cooldown %ss" % AbilityDefinition.format_number(ability.cooldown_at(shown)))
	if ability.cast_range > 0.0:
		facts.append("Range %s m" % AbilityDefinition.format_number(snappedf(ability.cast_range, 0.1)))
	if ability.radius > 0.0:
		facts.append("Area %s m" % AbilityDefinition.format_number(snappedf(ability.radius, 0.1)))
	if ability.channel_time_at(shown) > 0.0:
		facts.append("Channel %ss" % AbilityDefinition.format_number(ability.channel_time_at(shown)))
	if not facts.is_empty():
		lines.append("  ·  ".join(facts))
	lines.append("[color=#a0a0a0]%s[/color]" % ACTION_NAMES[ability.action])
	if not from_item and level < ability.max_level:
		var required := ability.required_hero_level(level + 1)
		var learn := "Ctrl+%s or the + badge to learn" % hotkey if unit.can_learn(slot) else "Requires hero level %d" % required
		lines.append("[color=#80d080]Next level: %s[/color]\n[color=#a0a0a0]%s[/color]" % [ability.describe(level + 1), learn])
	return "\n".join(lines)


## A passive with what each of its conversions gives this unit right now.
static func passive_tooltip(unit: Unit, passive: ClassPassive) -> String:
	var kind := "Faction passive" if passive == UnitDefinition.UNDEAD_PASSIVE else "Class passive"
	var lines: Array[String] = ["[b]%s[/b]   [color=#a0a0a0]%s[/color]" % [passive.display_name, kind]]
	if not passive.description.is_empty():
		lines.append(passive.description)
	for stat: Stats.Stat in passive.bonuses:
		lines.append("[color=#80d080]%s[/color]" % Stats.format_bonus(stat, passive.bonuses[stat]))
	for conversion in passive.conversions:
		var amount := unit.stats.value(conversion.from) * conversion.per_point
		var unit_name := " rating" if conversion.to in Stats.RATINGS else ""
		lines.append("[b]%s[/b] → %s: %s%s per point  [color=#80d080](%s%s)[/color]" % [Stats.NAMES[conversion.from],
				Stats.NAMES[conversion.to], Stats.format_amount(conversion.to, conversion.per_point), unit_name,
				Stats.format_amount(conversion.to, snappedf(amount, 0.001)), unit_name])
	return "\n".join(lines)


static func attack_type_tooltip(attack: AttackType, source: String) -> String:
	return "[b]Attack type: %s[/b]\n%s\n[color=#a0a0a0]From %s[/color]" % [attack.display_name, attack.describe(), source]
