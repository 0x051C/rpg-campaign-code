class_name DefeatWindow
extends EconomyWindow

## The whole party has fallen: load the last save, or go back to the title screen.


func build() -> void:
	content.add_child(label("Your party has fallen.", 30))
	var saves := Campaign.current.list_saves()
	var newest: Dictionary = saves[0] if not saves.is_empty() else {}
	if not newest.is_empty():
		content.add_child(label("The last save: %s" % SaveSlots.describe(newest.label, newest), 16, DIM))
		content.add_child(button("Load the last save", func() -> void:
			close()
			Campaign.current.load_game(newest.slot)))
	content.add_child(button("Quit to title", func() -> void:
		close()
		Campaign.current.quit_to_title()))


func _unhandled_input(_event: InputEvent) -> void:
	pass  # no Esc out of it: there's nothing to go back to
