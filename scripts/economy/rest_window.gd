class_name RestWindow
extends EconomyWindow

## The inn's offer (Inn): the night's price, a meal to go with it, and the party's gold.

var inn: Inn

var _meal: Meal
var _total: Label
var _stay: Button
var _note: Label


func build() -> void:
	content.add_child(label(inn.title, 28))
	content.add_child(label("A bed for the whole party: %d gold. Day %d." % [inn.price, Inn.day()], 18, DIM))
	content.add_child(label("Supper", 20, GOLD))
	var group := ButtonGroup.new()
	var none := CheckBox.new()
	none.text = "Nothing, thanks"
	none.button_group = group
	none.button_pressed = true
	none.toggled.connect(func(on: bool) -> void:
		if on:
			_choose(null))
	content.add_child(none)
	for meal in inn.meals:
		var choice := CheckBox.new()
		choice.text = "%s  —  %d gold:  %s" % [meal.display_name, meal.price, meal.description]
		choice.button_group = group
		choice.toggled.connect(func(on: bool) -> void:
			if on:
				_choose(meal))
		content.add_child(choice)
	_total = label("", 18, GOLD)
	content.add_child(_total)
	_note = label("", 16, Color(0.95, 0.5, 0.4))
	content.add_child(_note)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 12)
	_stay = button("Stay the night", _stay_the_night)
	row.add_child(_stay)
	row.add_child(button("Not tonight", close))
	content.add_child(row)


func refresh() -> void:
	var gold := party().gold if party() != null else 0
	var cost := inn.price + (_meal.price if _meal != null else 0)
	_total.text = "The night: %d gold.   You have %d." % [cost, gold]
	_stay.disabled = cost > gold
	_note.text = "" if cost <= gold else "Not enough gold. The jobs pay, and so does the Pit."


func _choose(meal: Meal) -> void:
	_meal = meal
	refresh()


func _stay_the_night() -> void:
	var error := inn.rest(_meal)
	if not error.is_empty():
		_note.text = error
		Sounds.error()
		return
	close()
