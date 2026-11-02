class_name DialogueOverlay
extends Control

## Speech bubbles over neutral NPCs that are being talked to (UnitRegistry.talk). Each line
## streams in letter by letter, stays a moment, then the next one starts. Talking to the
## NPC again finishes the line being written, or skips to the next one. Walking away ends
## the conversation. Lines are laid out once at full length, so words never jump between
## rows while they appear.

const FONT_SIZE := 16
const NAME_SIZE := 13
const MAX_WIDTH := 300.0
const PADDING := Vector2(12.0, 8.0)
const LIFT := 0.9  ## meters above the unit's head
const LEAVE_DISTANCE := 8.0  ## the speaker walking this far away ends the talk
const FADE_TIME := 0.4
const TEXT_COLOR := Color(0.95, 0.93, 0.88)
const NAME_COLOR := Color(0.95, 0.8, 0.35)

## One NPC talking.
class Talk:
	var npc := UnitRegistry.NONE
	var speaker := UnitRegistry.NONE
	var dialogue: Dialogue
	var line := 0
	var shown := 0.0  ## letters of the line visible
	var held := 0.0  ## seconds the full line has been shown
	var fade := 1.0  ## 1 while talking, down to 0 when the talk ends
	var ending := false
	var paragraph: TextParagraph

@export var registry: UnitRegistry

var _talks: Dictionary[int, Talk] = {}
var _heard: Dictionary[int, bool] = {}  ## NPCs that finished talking once (they go on from repeat_from)
var _style := StyleBoxFlat.new()
var _font: Font


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = ThemeDB.fallback_font
	_style.bg_color = Color(0.06, 0.07, 0.09, 0.82)
	_style.border_color = Color(0.95, 0.8, 0.35, 0.6)
	_style.set_border_width_all(1)
	_style.set_corner_radius_all(8)
	registry.talked_to.connect(_on_talked_to)


## True while the NPC is saying something.
func is_talking(npc: int) -> bool:
	return _talks.has(npc) and not _talks[npc].ending


func _on_talked_to(npc: int, speaker: int) -> void:
	var dialogue := registry.dialogue_of(npc)
	if dialogue == null or dialogue.lines.is_empty():
		return
	var talk: Talk = _talks.get(npc)
	if talk != null and not talk.ending:
		talk.speaker = speaker
		if talk.shown < talk.paragraph.get_range().y:
			talk.shown = talk.paragraph.get_range().y  # finish the line being written
		else:
			_next_line(talk)
		return
	var first := clampi(dialogue.repeat_from, 0, dialogue.lines.size() - 1) if _heard.has(npc) else 0
	talk = Talk.new()
	talk.npc = npc
	talk.speaker = speaker
	talk.dialogue = dialogue
	_talks[npc] = talk
	_start_line(talk, first)


func _process(delta: float) -> void:
	var writing := false
	for npc in _talks.keys():
		var talk := _talks[npc]
		if talk.ending:
			talk.fade -= delta / FADE_TIME
			if talk.fade <= 0.0:
				_talks.erase(npc)
			continue
		if not registry.is_alive(npc) or not registry.is_alive(talk.speaker) \
				or _distance(npc, talk.speaker) > LEAVE_DISTANCE:
			_end(talk)
			continue
		var length := talk.paragraph.get_range().y
		if talk.shown < length:
			talk.shown = minf(talk.shown + talk.dialogue.characters_per_second * delta, length)
			writing = true
		else:
			talk.held += delta
			if talk.held >= talk.dialogue.line_pause:
				_next_line(talk)
	Sounds.typing(writing)  # the letters scrolling in
	queue_redraw()


func _draw() -> void:
	var view := get_viewport().get_camera_3d()
	if view == null:
		return
	for talk: Talk in _talks.values():
		if not registry.is_alive(talk.npc):
			continue
		var head := Terrain.lift(registry.position_of(talk.npc)) + Vector3.UP * (registry.height_of(talk.npc) + LIFT)
		if view.is_position_behind(head):
			continue
		var anchor := view.unproject_position(head)
		var title := talk.dialogue.speaker if not talk.dialogue.speaker.is_empty() else registry.definition_of(talk.npc).display_name
		var text_size := talk.paragraph.get_size()
		var title_height := _font.get_height(NAME_SIZE)
		var box_size := Vector2(maxf(text_size.x, _font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_SIZE).x),
				title_height + text_size.y) + PADDING * 2.0
		var box := Rect2(anchor - Vector2(box_size.x * 0.5, box_size.y + 10.0), box_size)
		var alpha := clampf(talk.fade, 0.0, 1.0)
		var style := _style.duplicate() as StyleBoxFlat
		style.bg_color.a *= alpha
		style.border_color.a *= alpha
		draw_style_box(style, box)
		var tail := PackedVector2Array([anchor - Vector2(7.0, 10.0), anchor - Vector2(-7.0, 10.0), anchor - Vector2(0.0, 1.0)])
		draw_colored_polygon(tail, style.bg_color)
		var at := box.position + PADDING
		draw_string(_font, at + Vector2(0.0, _font.get_ascent(NAME_SIZE)), title, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_SIZE, Color(NAME_COLOR, alpha))
		_draw_visible(talk, at + Vector2(0.0, title_height), Color(TEXT_COLOR, alpha))


## The paragraph's rows, cut at the letters shown so far.
func _draw_visible(talk: Talk, at: Vector2, color: Color) -> void:
	var paragraph := talk.paragraph
	var text: String = talk.dialogue.lines[talk.line]
	var shown := int(talk.shown)
	var y := 0.0
	for row in paragraph.get_line_count():
		var span := paragraph.get_line_range(row)
		var row_size := paragraph.get_line_size(row)
		if span.x < shown:
			var written := text.substr(span.x, mini(span.y, shown) - span.x)
			draw_string(_font, at + Vector2(0.0, y + paragraph.get_line_ascent(row)), written, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, color)
		y += row_size.y


func _start_line(talk: Talk, line: int) -> void:
	talk.line = line
	talk.shown = 0.0
	talk.held = 0.0
	talk.paragraph = TextParagraph.new()
	talk.paragraph.add_string(talk.dialogue.lines[line], _font, FONT_SIZE)
	talk.paragraph.width = MAX_WIDTH
	talk.paragraph.break_flags = TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE


func _next_line(talk: Talk) -> void:
	if talk.line + 1 < talk.dialogue.lines.size():
		_start_line(talk, talk.line + 1)
	else:
		_end(talk)


func _end(talk: Talk) -> void:
	talk.ending = true
	_heard[talk.npc] = true
	registry.stop_listening(talk.npc)
	registry.finish_dialogue(talk.npc, talk.speaker)


func _distance(a: int, b: int) -> float:
	var offset := registry.position_of(a) - registry.position_of(b)
	return Vector2(offset.x, offset.z).length()
