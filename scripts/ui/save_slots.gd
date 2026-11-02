class_name SaveSlots
extends VBoxContainer

## The save slots list (SAVES.md): six slots to save into, and when loading also the quick
## save and the autosave. Each row shows what's in it: label, heroes and levels, play time
## and when it was saved. Saving over a used slot asks for a second click.

signal chosen(slot: String)
signal cancelled

enum Mode { SAVE, LOAD }

const SLOTS := 6
const CONFIRM_TIME_MS := 3000

var mode := Mode.LOAD

var _title := Label.new()
var _rows := VBoxContainer.new()
var _note := Label.new()
var _confirm_slot := ""
var _confirm_until := 0


func _ready() -> void:
	add_theme_constant_override(&"separation", 10)
	_title.add_theme_font_size_override(&"font_size", 30)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_title)
	_rows.add_theme_constant_override(&"separation", 4)
	add_child(_rows)
	_note.modulate = Color(1.0, 0.6, 0.5)
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_note)
	var back := Button.new()
	back.text = "Back"
	back.pressed.connect(cancelled.emit)
	add_child(back)


## Fills the list for saving or loading; `note` explains when saving isn't possible.
func show_slots(slot_mode: Mode, note := "") -> void:
	mode = slot_mode
	_title.text = "Save game" if mode == Mode.SAVE else "Load game"
	_note.text = note
	_note.visible = not note.is_empty()
	_confirm_slot = ""
	for child in _rows.get_children():
		child.queue_free()
	var headers := {}
	for header in Campaign.current.list_saves():
		headers[header.slot] = header
	var slots: Array[String] = []
	for i in SLOTS:
		slots.append("slot%d" % (i + 1))
	if mode == Mode.LOAD:
		slots.append_array([Campaign.QUICK_SLOT, Campaign.AUTO_SLOT])
		if headers.has(Campaign.RECOVERY_SLOT):
			slots.append(Campaign.RECOVERY_SLOT)  # only after a crash
	for i in slots.size():
		var slot := slots[i]
		var button := Button.new()
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_font_size_override(&"font_size", 18)
		button.custom_minimum_size = Vector2(620, 0)
		button.text = describe(_slot_name(slot, i), headers.get(slot, {}))
		button.disabled = (mode == Mode.LOAD and not headers.has(slot)) or (mode == Mode.SAVE and not note.is_empty())
		button.pressed.connect(_on_pressed.bind(slot, headers.has(slot), button))
		_rows.add_child(button)


## "Slot 2 — Village   Knight 3 · Rogue 2 · Mage 2   0:42   2026-10-16 14:03" or "Slot 2 — empty".
static func describe(slot_name: String, header: Dictionary) -> String:
	if header.is_empty():
		return "%s — empty" % slot_name
	var heroes: Array[String] = []
	for hero: Dictionary in header.get("heroes", []):
		heroes.append("%s %d" % [hero.name, hero.level])
	var minutes := floori(header.play_time / 60.0)
	var when := Time.get_datetime_string_from_unix_time(int(header.saved_at), true).substr(0, 16)
	return "%s — %s\n      %s   ·   %d:%02d played   ·   %s" % [slot_name, header.label, " · ".join(heroes),
			floori(minutes / 60.0), minutes % 60, when]


func _slot_name(slot: String, index: int) -> String:
	match slot:
		Campaign.QUICK_SLOT:
			return "Quick save"
		Campaign.AUTO_SLOT:
			return "Autosave"
		Campaign.RECOVERY_SLOT:
			return "Before the crash"
	return "Slot %d" % (index + 1)


func _on_pressed(slot: String, used: bool, button: Button) -> void:
	if mode == Mode.SAVE and used and (_confirm_slot != slot or Time.get_ticks_msec() > _confirm_until):
		_confirm_slot = slot
		_confirm_until = Time.get_ticks_msec() + CONFIRM_TIME_MS
		button.text = "Overwrite this save? Click again."
		return
	chosen.emit(slot)
