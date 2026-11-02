class_name ConfirmWindow
extends EconomyWindow

## A yes-or-no question over the paused game, in the menus' style: the arena asking whether the party
## will fight and be worn out for the day. `answered(true)` for yes; Esc or no is `answered(false)`.

signal answered(yes: bool)

var title := ""
var text := ""
var yes_text := "Yes"
var no_text := "No"

var _answered := false


static func ask(tree: SceneTree, question_title: String, question_text: String, yes_label: String, no_label: String) -> ConfirmWindow:
	var window := ConfirmWindow.new()
	window.title = question_title
	window.text = question_text
	window.yes_text = yes_label
	window.no_text = no_label
	tree.root.add_child(window)
	return window


func build() -> void:
	content.add_child(label(title, 26, GOLD))
	content.add_child(label(text, 17))
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 12)
	row.add_child(button(yes_text, _answer.bind(true)))
	row.add_child(button(no_text, _answer.bind(false)))
	content.add_child(row)


func close() -> void:
	if not _answered:
		_answered = true
		answered.emit(false)
	super()


func _answer(yes: bool) -> void:
	_answered = true
	answered.emit(yes)
	close()
