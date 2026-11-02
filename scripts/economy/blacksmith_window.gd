class_name BlacksmithWindow
extends EconomyWindow

## The smith's forge (Blacksmith, Forge): the party's found items in the bag on the left; the chosen
## one on the right, each rolled line with a reroll and a carry-over, and the tempering below. Carrying
## a line over: pick the item that takes it on the left (and, if it's full, which of its lines it
## replaces); the item it came from goes into the fire. Tokens are bought here too.

var smith: Blacksmith

var _tokens: Label
var _note: Label
var _items := VBoxContainer.new()
var _detail := VBoxContainer.new()
var _selected: ItemDefinition
var _carrying := {}  ## {item, stat}: a line on its way to another item
var _target: ItemDefinition  ## a full item picked to take the carried line


func build() -> void:
	content.custom_minimum_size = Vector2(900, 0)
	content.add_child(label(smith.title, 28))
	var top := HBoxContainer.new()
	top.add_theme_constant_override(&"separation", 14)
	_tokens = label("", 18, GOLD)
	_tokens.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_tokens)
	top.add_child(button("Buy a token (%d gold)" % smith.token_price, func() -> void: _report(smith.buy_token())))
	content.add_child(top)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override(&"separation", 18)
	content.add_child(columns)
	for entry: Array in [["Your finds", _items, 340], ["At the anvil", _detail, 520]]:
		var column := VBoxContainer.new()
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_child(label(entry[0], 20, GOLD))
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(entry[2], 340)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		(entry[1] as VBoxContainer).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(entry[1])
		column.add_child(scroll)
		columns.add_child(column)
	_note = label("", 16, Color(0.95, 0.5, 0.4))
	content.add_child(_note)
	content.add_child(button("Done", close))


func refresh() -> void:
	var party := party()
	if party == null:
		return
	_tokens.text = "You have %d gold and %d token%s." % [party.gold, party.tokens, "" if party.tokens == 1 else "s"]
	for child in _items.get_children() + _detail.get_children():
		child.queue_free()
	var finds := _finds()
	if finds.is_empty():
		_items.add_child(label("Nothing found out there yet: magic, rare and legendary things, in the bag.", 15, DIM))
	for item in finds:
		var text := "%s   (item level %d)" % [item.display_name, item.item_level]
		var choose := button(text, _choose.bind(item))
		choose.add_theme_color_override(&"font_color", item.name_color())
		if item == _selected or (not _carrying.is_empty() and item == _carrying.item):
			choose.disabled = true
		_items.add_child(choose)
	if not _carrying.is_empty():
		_show_carrying()
	elif _selected != null and party.bag.has(_selected):
		_show_item(_selected)
	else:
		_detail.add_child(label("Pick something to work on.", 15, DIM))


## The bag's found items: what came out of a monster, a chest or the Pit.
func _finds() -> Array[ItemDefinition]:
	var finds: Array[ItemDefinition] = []
	for item in party().bag:
		if item.base_item != null:
			finds.append(item)
	return finds


func _show_item(item: ItemDefinition) -> void:
	var title := label(item.display_name, 20, item.name_color())
	_detail.add_child(title)
	_detail.add_child(label(EconomyWindow.describe(item), 14, DIM))
	if item.rolled.is_empty():
		_detail.add_child(label("No rolled lines: nothing to reroll or carry. It can still take one carried over.", 15, DIM))
	for stat: Stats.Stat in item.rolled:
		var row := HBoxContainer.new()
		var line := label("%s   (%s)" % [Stats.format_bonus(stat, item.rolled[stat]), item.affix_words.get(stat, "?")], 15)
		line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(line)
		row.add_child(button("Reroll  %d" % smith.reroll_cost, func() -> void:
			_report(smith.work(smith.reroll_cost, Forge.reroll.bind(item, stat)))))
		row.add_child(button("Carry over  %d" % smith.transfer_cost, func() -> void:
			_carrying = {"item": item, "stat": stat}
			_target = null
			_note.text = ""
			refresh()))
		_detail.add_child(row)
	_detail.add_child(button("Temper: +%d item levels, every line grows  (%d tokens)" % [smith.temper_levels, smith.temper_cost],
			func() -> void: _report(smith.work(smith.temper_cost, Forge.temper.bind(item, smith.temper_levels)))))


func _show_carrying() -> void:
	var source: ItemDefinition = _carrying.item
	var stat: Stats.Stat = _carrying.stat
	_detail.add_child(label("Carrying %s from %s." % [Stats.format_bonus(stat, source.rolled.get(stat, 0.0)), source.display_name], 16, GOLD))
	_detail.add_child(label("Pick the item to carry it to, on the left. %s goes into the fire." % source.display_name, 15, DIM))
	if _target != null:
		_detail.add_child(label("%s is full: which line does it give up?" % _target.display_name, 15))
		for line_stat: Stats.Stat in _target.rolled:
			_detail.add_child(button("Replace %s" % Stats.format_bonus(line_stat, _target.rolled[line_stat]),
					_carry.bind(_target, line_stat)))
	_detail.add_child(button("Never mind", func() -> void:
		_carrying = {}
		_target = null
		refresh()))


func _choose(item: ItemDefinition) -> void:
	_note.text = ""
	if _carrying.is_empty():
		_selected = item
		refresh()
		return
	if item.rolled.size() >= Forge.ROOM.get(item.rarity, 0) and not item.rolled.has(_carrying.stat):
		_target = item  # full: it gives up a line
		refresh()
		return
	_carry(item, _carrying.stat if item.rolled.has(_carrying.stat) else -1)


## Carries the line to `target` (giving up `replace`), and the source goes into the fire.
func _carry(target: ItemDefinition, replace: int) -> void:
	var source: ItemDefinition = _carrying.item
	var stat: Stats.Stat = _carrying.stat
	var error := smith.work(smith.transfer_cost, Forge.transfer.bind(source, stat, target, replace))
	if error.is_empty():
		var party := party()
		var index := party.bag.find(source)
		if index >= 0:
			party.take_from_bag(index)
		_carrying = {}
		_target = null
		_selected = target
	_report(error)


func _report(error: String) -> void:
	_note.text = error
	if not error.is_empty():
		Sounds.error()
	refresh()
