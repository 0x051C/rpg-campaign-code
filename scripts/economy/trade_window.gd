class_name TradeWindow
extends EconomyWindow

## Trading with a Vendor: its stock to buy on the left, the party's bag to sell on the right.

var vendor: Vendor

var _gold: Label
var _note: Label
var _buy := VBoxContainer.new()
var _sell := VBoxContainer.new()


func build() -> void:
	content.custom_minimum_size = Vector2(860, 0)
	content.add_child(label(vendor.title, 28))
	_gold = label("", 18, GOLD)
	content.add_child(_gold)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override(&"separation", 18)
	content.add_child(columns)
	for entry: Array in [["Buy", _buy], ["Sell", _sell]]:
		var column := VBoxContainer.new()
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_child(label(entry[0], 20, GOLD))
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(400, 320)
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.add_child(entry[1])
		(entry[1] as VBoxContainer).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_child(scroll)
		columns.add_child(column)
	_note = label("", 16, Color(0.95, 0.5, 0.4))
	content.add_child(_note)
	content.add_child(button("Done", close))


func refresh() -> void:
	var party := party()
	var purse := "no end of gold" if vendor.purse < 0 else "%d gold" % vendor.purse
	_gold.text = "You have %d gold.   %s has %s." % [party.gold if party != null else 0, vendor.title, purse]
	for child in _buy.get_children() + _sell.get_children():
		child.queue_free()
	for i in vendor.stock.size():
		var item := vendor.stock[i]
		_buy.add_child(_row(item, "Buy  %d" % vendor.price_of(item), _do.bind(vendor.buy, i)))
	if vendor.stock.is_empty():
		_buy.add_child(label("Nothing left to sell you.", 16, DIM))
	if party != null:
		for i in party.bag.size():
			var item := party.bag[i]
			_sell.add_child(_row(item, "Sell  %d" % vendor.offer_for(item), _do.bind(vendor.sell, i)))
		if party.bag.is_empty():
			_sell.add_child(label("The bag is empty.", 16, DIM))


func _row(item: ItemDefinition, action: String, pressed: Callable) -> Control:
	var row := HBoxContainer.new()
	var text := label("%s\n%s" % [item.display_name, EconomyWindow.describe(item)], 15)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.tooltip_text = item.description
	text.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(text)
	row.add_child(button(action, pressed))
	return row


func _do(action: Callable, index: int) -> void:
	var error: String = action.call(index)
	_note.text = error
	if not error.is_empty():
		Sounds.error()
	refresh()
