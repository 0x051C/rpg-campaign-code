class_name InventoryWindow
extends PanelContainer

## The inventory and character window (STATS_AND_ITEMS.md), opened with I: the chosen hero's
## equipment, stats and passives, the party bag with its shared weight, and the 2×3 combine
## grid. The main stats show at once; the rest fold out under "Advanced stats" (Dark Souls 3
## style). Drag items
## between them. Right-click is the shortcut: wear a bag item (a component goes to the
## grid), take a worn item off, take a combined item apart. Hover anything for details.

const GROUP := &"inventory_window"
const CELL := 52.0
const BAG_CELL := 36.0
const WEIGHT_COLOR := Color(0.85, 0.7, 0.3)
const OVER_COLOR := Color(0.9, 0.3, 0.25)
const EQUIPMENT_COLUMNS := 3
const RINGS_FROM := 9  ## Equipment slots from here on are the rings, drawn in their own row
## Derived stats always shown; the others fold out under "Advanced stats".
const BASIC_STATS: Array[Stats.Stat] = [Stats.Stat.MAX_HEALTH, Stats.Stat.MAX_MANA, Stats.Stat.ATTACK_DAMAGE,
		Stats.Stat.ARMOR, Stats.Stat.MOVE_SPEED]

@export var inventory: PartyInventory
@export var commander: Commander

var hero: Unit

var _hero_row := HBoxContainer.new()
var _equipment_cells: Array[ItemCell] = []
var _combine_cells: Array[ItemCell] = []
var _bag_rows := VBoxContainer.new()
var _bag_scroll := ScrollContainer.new()
var _weight := Control.new()
var _stats_text := RichTextLabel.new()
var _tooltip := PanelContainer.new()
var _tooltip_text := RichTextLabel.new()
var _hovered_cell: ItemCell
var _hovered_meta := ""  ## "stat:N" or "passive:N" under the mouse in the stats text
var _advanced_open := false


func _ready() -> void:
	visible = false
	add_to_group(GROUP)
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override(&"panel", _panel_style(0.95, 14))

	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 8)
	add_child(column)

	var title_row := HBoxContainer.new()
	column.add_child(title_row)
	var title := Label.new()
	title.text = "Inventory"
	title.add_theme_font_size_override(&"font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)
	var close := Button.new()
	close.text = "Close (I)"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(toggle)
	title_row.add_child(close)

	_weight.custom_minimum_size = Vector2(0, 18)
	_weight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_weight.draw.connect(_draw_weight)
	column.add_child(_weight)

	var body := HBoxContainer.new()
	body.add_theme_constant_override(&"separation", 16)
	column.add_child(body)
	body.add_child(_build_hero_column())
	body.add_child(_build_stats_column())
	body.add_child(_build_bag_column())
	body.add_child(_build_combine_column())

	_tooltip.top_level = true
	_tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.add_theme_stylebox_override(&"panel", _panel_style(0.97, 8))
	_tooltip.visible = false
	_tooltip_text.bbcode_enabled = true
	_tooltip_text.fit_content = true
	_tooltip_text.scroll_active = false
	_tooltip_text.custom_minimum_size = Vector2(280, 0)
	_tooltip_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip.add_child(_tooltip_text)
	add_child(_tooltip)

	inventory.changed.connect(_refresh)
	inventory.assembled.connect(func(item: ItemDefinition) -> void:
		commander.show_message("Combined: %s" % item.display_name, PartyInventory.GOOD_NEWS))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"rts_inventory"):
		toggle()
		get_viewport().set_input_as_handled()
	elif visible and event.is_action_pressed(&"rts_cancel"):
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	visible = not visible
	if visible:
		var active := commander.registry.unit_of(commander.get_selected_control())
		if active == null or not commander.heroes.has(active.handle):
			active = inventory.heroes()[0] if not inventory.heroes().is_empty() else null
		_show_hero(active)
		reset_size()
		set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	else:
		_tooltip.visible = false


func _process(_delta: float) -> void:
	if not visible:
		return
	_update_tooltip()


# --- Moving items (called by the cells) ----------------------------------------

func can_drop(source: PartyInventory.Place, target: PartyInventory.Place) -> bool:
	var item := inventory.item_at(source)
	if item == null or (source.area == PartyInventory.Area.BAG and target.area == PartyInventory.Area.BAG):
		return false
	return inventory.refusal(target, item).is_empty()


func drop(source: PartyInventory.Place, target: PartyInventory.Place) -> void:
	_report(inventory.move(source, target))


func quick_move(place: PartyInventory.Place) -> void:
	_report(inventory.quick_move(place, hero))


func hover_cell(cell: ItemCell) -> void:
	_hovered_cell = cell


func unhover_cell(cell: ItemCell) -> void:
	if _hovered_cell == cell:
		_hovered_cell = null


func _report(error: String) -> void:
	if not error.is_empty():
		commander.show_error(error)


# --- Layout --------------------------------------------------------------------

func _build_hero_column() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 6)
	box.add_child(_hero_row)
	var grid := GridContainer.new()
	grid.columns = EQUIPMENT_COLUMNS
	grid.add_theme_constant_override(&"h_separation", 6)
	grid.add_theme_constant_override(&"v_separation", 6)
	box.add_child(grid)
	var rings := HBoxContainer.new()
	rings.add_theme_constant_override(&"separation", 6)
	box.add_child(rings)
	for index in Equipment.count():
		var cell := ItemCell.new(CELL)
		cell.window = self
		cell.caption = Equipment.slot_name(index)
		if index >= RINGS_FROM:
			rings.add_child(cell)
		else:
			grid.add_child(cell)
		_equipment_cells.append(cell)
	return box


func _build_stats_column() -> Control:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(320, 380)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_stats_text.bbcode_enabled = true
	_stats_text.fit_content = true
	_stats_text.scroll_active = false
	_stats_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats_text.meta_underlined = false
	_stats_text.meta_hover_started.connect(func(meta: Variant) -> void:
		_hovered_meta = str(meta))
	_stats_text.meta_hover_ended.connect(func(_meta: Variant) -> void:
		_hovered_meta = "")
	_stats_text.meta_clicked.connect(func(meta: Variant) -> void:
		if str(meta) == "advanced":
			_advanced_open = not _advanced_open
			_refresh())
	scroll.add_child(_stats_text)
	return scroll


func _build_bag_column() -> Control:
	var box := VBoxContainer.new()
	var label := Label.new()
	label.text = "Bag (shared by the party)"
	box.add_child(label)
	_bag_scroll.custom_minimum_size = Vector2(260, 330)
	_bag_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Dropping anywhere on the bag puts the item in it
	_bag_scroll.set_drag_forwarding(Callable(),
		func(_at: Vector2, data: Variant) -> bool:
			return data is PartyInventory.Place and can_drop(data, _bag_place()),
		func(_at: Vector2, data: Variant) -> void:
			drop(data, _bag_place()))
	_bag_rows.add_theme_constant_override(&"separation", 2)
	_bag_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bag_scroll.add_child(_bag_rows)
	box.add_child(_bag_scroll)
	return box


func _build_combine_column() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 6)
	var label := Label.new()
	label.text = "Combine"
	box.add_child(label)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override(&"h_separation", 6)
	grid.add_theme_constant_override(&"v_separation", 6)
	box.add_child(grid)
	for cell_index in PartyInventory.COMBINE_CELLS:
		var cell := ItemCell.new(CELL)
		cell.window = self
		cell.place = PartyInventory.Place.new(PartyInventory.Area.COMBINE, cell_index)
		grid.add_child(cell)
		_combine_cells.append(cell)
	var hint := Label.new()
	hint.text = "Put every part of a recipe here and they combine into the item.\nRight-click a combined item to take it apart."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(180, 0)
	hint.add_theme_font_size_override(&"font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.6)
	box.add_child(hint)
	return box


static func _panel_style(opacity: float, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.09, opacity)
	style.border_color = Color(0.4, 0.4, 0.45)
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(margin)
	return style


func _bag_place() -> PartyInventory.Place:
	return PartyInventory.Place.new(PartyInventory.Area.BAG, 0)


# --- Contents ------------------------------------------------------------------

func _show_hero(shown: Unit) -> void:
	if hero != null and hero.stats_changed.is_connected(_refresh):
		hero.stats_changed.disconnect(_refresh)
	hero = shown
	if hero != null:
		hero.stats_changed.connect(_refresh)
	_refresh()


func _refresh() -> void:
	if not is_inside_tree():
		return
	# Hero buttons
	var heroes := inventory.heroes()
	for child in _hero_row.get_children():
		child.queue_free()
	for each in heroes:
		var button := Button.new()
		button.text = each.definition.display_name
		button.toggle_mode = true
		button.button_pressed = each == hero
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_show_hero.bind(each))
		_hero_row.add_child(button)
	# Equipment
	for index in _equipment_cells.size():
		var cell := _equipment_cells[index]
		cell.place = PartyInventory.Place.new(PartyInventory.Area.EQUIPMENT, index, hero)
		cell.item = hero.equipment[index] if hero != null else null
	# Combine grid
	for cell_index in _combine_cells.size():
		_combine_cells[cell_index].item = inventory.combine[cell_index]
	# Bag, heaviest first
	for child in _bag_rows.get_children():
		child.queue_free()
	for bag_index in inventory.bag.size():
		var item := inventory.bag[bag_index]
		var row := HBoxContainer.new()
		var cell := ItemCell.new(BAG_CELL)
		cell.window = self
		cell.place = PartyInventory.Place.new(PartyInventory.Area.BAG, bag_index)
		cell.item = item
		row.add_child(cell)
		var name_label := Label.new()
		name_label.text = "%s\n%s · %s kg" % [item.display_name, ItemDefinition.SLOT_NAMES[item.slot],
				AbilityDefinition.format_number(snappedf(item.weight, 0.1))]
		name_label.add_theme_font_size_override(&"font_size", 12)
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(name_label)
		_bag_rows.add_child(row)
	_weight.queue_redraw()
	_stats_text.text = _stats_bbcode()


func _draw_weight() -> void:
	var carried := inventory.carried_weight()
	var capacity := inventory.capacity
	var rect := Rect2(Vector2.ZERO, _weight.size)
	_weight.draw_rect(rect, Color(0, 0, 0, 0.6))
	var fraction := clampf(carried / capacity, 0.0, 1.0) if capacity > 0.0 else 1.0
	_weight.draw_rect(Rect2(rect.position, Vector2(rect.size.x * fraction, rect.size.y)), OVER_COLOR if carried > capacity else WEIGHT_COLOR)
	var label := "%d gold   ·   Bag weight %s / %s kg (worn items don't count)" % [inventory.gold, AbilityDefinition.format_number(snappedf(carried, 0.1)), AbilityDefinition.format_number(snappedf(capacity, 0.1))]
	var font := get_theme_default_font()
	var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	_weight.draw_string_outline(font, Vector2((rect.size.x - width) * 0.5, 13), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color.BLACK)
	_weight.draw_string(font, Vector2((rect.size.x - width) * 0.5, 13), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)


## The hero's core stats, main derived stats, passives, and the advanced stats folded out on
## request; every name links to a breakdown tooltip.
func _stats_bbcode() -> String:
	if hero == null:
		return ""
	var sheet := hero.stats
	var lines: Array[String] = ["[b]%s[/b]   Level %d" % [hero.definition.display_name, hero.level]]
	for stat in Stats.CORE:
		lines.append("[url=stat:%d]%s[/url]   [b]%s[/b]" % [stat, Stats.NAMES[stat],
				AbilityDefinition.format_number(snappedf(sheet.value(stat), 0.1))])
	lines.append("")
	for stat in BASIC_STATS:
		lines.append(_stat_line(stat))
	var attack := hero.attack_type()
	lines.append("Armor type   %s" % Stats.ARMOR_NAMES[hero.definition.armor_type])
	lines.append("Attack type   %s" % (attack.display_name if attack != null else "Normal"))
	var passives := hero.definition.all_passives()
	if not passives.is_empty():
		lines.append("")
		lines.append("[b]Passives[/b]")
		for i in passives.size():
			lines.append("[url=passive:%d]%s[/url]   [color=#80d080]%s[/color]" % [i, passives[i].display_name,
					_passive_summary(passives[i])])
	lines.append("")
	lines.append("[url=advanced][color=#c0b0ff]Advanced stats %s[/color][/url]" % ("▾" if _advanced_open else "▸"))
	if _advanced_open:
		for stat in Stats.DERIVED_ORDER:
			if not stat in BASIC_STATS:
				lines.append(_stat_line(stat))
	return "\n".join(lines)


func _stat_line(stat: Stats.Stat) -> String:
	return "[url=stat:%d]%s[/url]   %s" % [stat, Stats.NAMES[stat], Stats.format_value(stat, hero.stats.value(stat))]


## What a passive gives this hero right now, in a few words: "+4.4 Armor", "+25% Backstab damage".
func _passive_summary(passive: ClassPassive) -> String:
	var parts: Array[String] = []
	for stat: Stats.Stat in passive.bonuses:
		parts.append(Stats.format_bonus(stat, passive.bonuses[stat]))
	for conversion in passive.conversions:
		parts.append(Stats.format_bonus(conversion.to, snappedf(hero.stats.value(conversion.from) * conversion.per_point, 0.01)))
	if parts.is_empty():
		return "hover for its rules"
	return ", ".join(parts)


# --- Tooltips ------------------------------------------------------------------

func _update_tooltip() -> void:
	var text := ""
	if _hovered_cell != null and is_instance_valid(_hovered_cell) and _hovered_cell.item != null:
		text = item_tooltip(_hovered_cell.item, inventory.catalog)
	elif _hovered_meta.begins_with("stat:") and hero != null:
		text = _stat_tooltip(_hovered_meta.get_slice(":", 1).to_int() as Stats.Stat)
	elif _hovered_meta.begins_with("passive:") and hero != null:
		var passives := hero.definition.all_passives()
		var index := _hovered_meta.get_slice(":", 1).to_int()
		if index < passives.size():
			text = SpellPanel.passive_tooltip(hero, passives[index])
	_tooltip.visible = not text.is_empty()
	if not _tooltip.visible:
		return
	_tooltip_text.text = text
	_tooltip.reset_size()
	var at := get_global_mouse_position() + Vector2(18, 18)
	var screen := get_viewport_rect().size
	at.x = minf(at.x, screen.x - _tooltip.size.x - 4)
	at.y = minf(at.y, screen.y - _tooltip.size.y - 4)
	_tooltip.global_position = at


## Where a stat's total comes from, line by line.
func _stat_tooltip(stat: Stats.Stat) -> String:
	var sheet := hero.stats
	var lines: Array[String] = ["[b]%s[/b]   %s" % [Stats.NAMES[stat], Stats.format_value(stat, sheet.value(stat))]]
	for source: Array in sheet.sources[stat]:
		lines.append("%s   [color=#a0a0a0]%s[/color]" % [Stats.format_bonus(stat, snappedf(source[1], 0.01)), source[0]])
	if stat in Stats.RATINGS:
		lines.append("[color=#a0a0a0]%s rating gives %s (rating / (100 + rating))[/color]" % [
				AbilityDefinition.format_number(snappedf(sheet.value(stat), 0.1)), Stats.format_value(stat, sheet.value(stat))])
	if Stats.is_core(stat):
		lines.append("[color=#a0a0a0]Every point: %s[/color]" % Stats.format_bonus(Stats.GENERAL_BONUS[stat], Stats.GENERAL_PER_POINT[stat]))
	if stat == Stats.Stat.STATUS_RESISTANCE or stat == Stats.Stat.SLOW_RESISTANCE:
		lines.append("[color=#a0a0a0]Nothing stuns or slows yet; this is ready for when something does.[/color]")
	return "\n".join(lines)


## The color an item's name shows in: its rarity's, or the named items' for recipe parts and results.
static func item_color(item: ItemDefinition, catalog: ItemCatalog) -> Color:
	if item.rarity == ItemDefinition.Rarity.COMMON and item.base_item == null and catalog != null \
			and (catalog.recipe_for(item) != null or not catalog.uses_of(item).is_empty()):
		return ItemDefinition.RARITY_COLORS[ItemDefinition.Rarity.NAMED]
	return item.name_color()


## An item's name, slot, weight, bonuses, attack type, ability and recipe links.
static func item_tooltip(item: ItemDefinition, catalog: ItemCatalog) -> String:
	var lines: Array[String] = ["[b][color=#%s]%s[/color][/b]   [color=#a0a0a0]%s · %s kg[/color]" % [
			item_color(item, catalog).to_html(false), item.display_name, ItemDefinition.SLOT_NAMES[item.slot],
			AbilityDefinition.format_number(snappedf(item.weight, 0.1))]]
	if item.base_item != null:  # rolled: what it was rolled from, and how deep it dropped
		var kind := ItemDefinition.RARITY_NAMES[item.rarity]
		lines.append("[color=#a0a0a0]%s%s, item level %d[/color]" % [kind + " " if not kind.is_empty() else "",
				item.base_item.display_name, item.item_level])
	var own := item.base_bonuses()
	for stat: Stats.Stat in own:
		lines.append("[color=#80d080]%s[/color]" % Stats.format_bonus(stat, own[stat]))
	for stat: Stats.Stat in item.rolled:  # the affixes' lines, apart from the base's
		lines.append("[color=#8ca8ff]%s[/color]" % Stats.format_bonus(stat, item.rolled[stat]))
	if item.power != null:  # a legendary's power, in its color
		lines.append("[color=#ff8c26]%s[/color]" % item.power.describe())
	if item.attack_type != null:
		lines.append("[color=#ffd860]Attack type: %s[/color]  %s" % [item.attack_type.display_name, item.attack_type.describe()])
	if item.ability != null:
		var ability := item.ability
		var facts: Array[String] = []
		if ability.mana_cost_at(1) > 0.0:
			facts.append("Mana %d" % ability.mana_cost_at(1))
		if ability.cooldown_at(1) > 0.0:
			facts.append("Cooldown %ss" % AbilityDefinition.format_number(ability.cooldown_at(1)))
		lines.append("[color=#8cb4ff]%s: %s %s[/color]" % [ability.display_name, ability.describe(1),
				"(%s)" % ", ".join(facts) if not facts.is_empty() else ""])
	if not item.description.is_empty():
		lines.append("[i]%s[/i]" % item.description)
	var recipe := catalog.recipe_for(item) if catalog != null else null
	if recipe != null:
		var parts: Array[String] = []
		for component in recipe.components:
			parts.append(component.display_name)
		lines.append("[color=#a0a0a0]Combined from: %s[/color]" % " + ".join(parts))
	if catalog != null:
		var uses: Array[String] = []
		for other in catalog.uses_of(item):
			uses.append(other.display_name)
		if not uses.is_empty():
			lines.append("[color=#a0a0a0]Part of: %s[/color]" % ", ".join(uses))
	return "\n".join(lines)
